--------------------------------------------------------------------------------
-- RETRO PLAYER v3.2 - app Lua (CSP) para Assetto Corsa
-- MP3/M4A/AAC/WAV | estações por pasta | visualizador pseudo-rítmico
-- skins Winamp / Rádio automotivo | cor RGB + saturação + brilho
-- v3.2: janela responsiva, corpo do aparelho preenche a janela inteira
--------------------------------------------------------------------------------

local EXTENSIONS = { mp3 = true, m4a = true, wav = true, aac = true }

local function rootFolder()
  local ok, p = pcall(function() return ac.getFolder(ac.FolderID.Root) end)
  return (ok and p and p ~= '') and p or 'C:'
end

local cfg = ac.storage{
  root = rootFolder() .. '\\music',
  volume = 0.7,
  shuffle = false,
  repeatAll = true,
  folder = 1,
  showRemaining = false,
  skin = 1,                 -- 1 = Winamp, 2 = Rádio
  colR = 209, colG = 115, colB = 255,
  sat = 1.0,                -- multiplicador de saturação (0..2)
  bright = 1.0,             -- multiplicador de brilho (0.3..1.5)
  bpmManual = 0,            -- 0 = automático
  intensity = 1.0,          -- intensidade do pulso (0.3..1.5)
}

--------------------------------------------------------------------------------
-- utilidades
--------------------------------------------------------------------------------
local function clamp01(v) return math.max(0, math.min(1, v)) end

local function hashStr(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 1000003 end
  return h
end

local function fmtTime(t)
  t = math.max(0, math.floor(t))
  return string.format('%02d:%02d', math.min(99, math.floor(t / 60)), t % 60)
end

--------------------------------------------------------------------------------
-- COR: RGB -> HSV -> paleta
--------------------------------------------------------------------------------
local function rgb2hsv(r, g, b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d, h = mx - mn, 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h / 6
  end
  return h, (mx == 0) and 0 or d / mx, mx
end

local function hsv2rgb(h, s, v)
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  i = i % 6
  if i == 0 then return v, t, p elseif i == 1 then return q, v, p
  elseif i == 2 then return p, v, t elseif i == 3 then return p, q, v
  elseif i == 4 then return t, p, v else return v, p, q end
end

local function hsv(h, s, v, a)
  local r, g, b = hsv2rgb(h, clamp01(s), clamp01(v))
  return rgbm(r, g, b, a or 1)
end

local PAL, palKey, gradCache = {}, nil, {}

local function updatePalette()
  local key = string.format('%d,%d,%d,%.3f,%.3f', cfg.colR, cfg.colG, cfg.colB, cfg.sat, cfg.bright)
  if key == palKey then return end
  palKey, gradCache = key, {}

  local h, s, v = rgb2hsv(cfg.colR / 255, cfg.colG / 255, cfg.colB / 255)
  s = clamp01(s * cfg.sat)
  v = clamp01(math.max(v, 0.05) * cfg.bright)
  PAL.h, PAL.s, PAL.v = h, s, v

  PAL.on      = hsv(h, s, v)
  PAL.glow    = hsv(h, s * 1.15, v, 0.20)
  PAL.text    = hsv(h, s * 0.9, v)
  PAL.dim     = hsv(h, s, v * 0.6, 0.55)
  PAL.segOff  = hsv(h, s, v * 0.4, 0.18)
  PAL.border  = hsv(h, s, v * 0.95, 0.45)
  PAL.dispTop = hsv(h, s * 1.3, 0.11)
  PAL.dispBot = hsv(h, s, 0.035)
  PAL.specLo  = hsv(h, s * 1.5, v * 0.75)
  PAL.specHi  = hsv(h, s * 0.55, v)
  PAL.peak    = hsv(h, s * 0.3, 1)
  PAL.seekA   = hsv(h, s * 1.5, v * 0.55)
  PAL.seekB   = hsv(h, s * 0.9, v)
end

local function palA(a) return hsv(PAL.h, PAL.s, PAL.v, a) end

local function lerpCol(a, b, k)
  return rgbm(a.r + (b.r - a.r) * k, a.g + (b.g - a.g) * k, a.b + (b.b - a.b) * k, 1)
end

local function grad(segs)
  local g = gradCache[segs]
  if not g then
    g = {}
    for s = 1, segs do g[s] = lerpCol(PAL.specLo, PAL.specHi, (s - 1) / math.max(1, segs - 1)) end
    gradCache[segs] = g
  end
  return g
end

--------------------------------------------------------------------------------
-- biblioteca (pasta principal -> estações)
--------------------------------------------------------------------------------
local library = {}

local function tryAddFile(name, full, list)
  local ext = name:match('%.(%w+)$')
  if ext and EXTENSIONS[ext:lower()] then
    list[#list + 1] = { path = full, title = (name:gsub('%.%w+$', '')), ext = ext:upper() }
  end
end

local function sortedItems(dir)
  local items = io.scanDir(dir, '*') or {}
  table.sort(items, function(a, b) return a:lower() < b:lower() end)
  return items
end

local function collect(dir, list, depth)
  for _, name in ipairs(sortedItems(dir)) do
    if name ~= '.' and name ~= '..' then
      local full = dir .. '\\' .. name
      if io.dirExists(full) then
        if depth < 4 then collect(full, list, depth + 1) end
      else
        tryAddFile(name, full, list)
      end
    end
  end
end

local function rescan()
  local root = cfg.root
  local newLib, all, rootFiles = {}, {}, {}
  if not io.dirExists(root) then pcall(io.createDir, root) end
  if io.dirExists(root) then
    for _, name in ipairs(sortedItems(root)) do
      if name ~= '.' and name ~= '..' then
        local full = root .. '\\' .. name
        if io.dirExists(full) then
          local tracks = {}
          collect(full, tracks, 1)
          if #tracks > 0 then newLib[#newLib + 1] = { name = name:upper(), tracks = tracks } end
        else
          tryAddFile(name, full, rootFiles)
        end
      end
    end
    if #rootFiles > 0 then newLib[#newLib + 1] = { name = 'RAIZ', tracks = rootFiles } end
  end
  for _, cat in ipairs(newLib) do
    for _, t in ipairs(cat.tracks) do all[#all + 1] = t end
  end
  if #all > 0 then table.insert(newLib, 1, { name = 'TODAS', tracks = all }) end
  library = newLib
  if cfg.folder < 1 or cfg.folder > #library then cfg.folder = 1 end
end

--------------------------------------------------------------------------------
-- reprodução
--------------------------------------------------------------------------------
local player, state, current = nil, 'stopped', 0
local advanceLock, clock = 0, 0
local trackBpm, trackPattern, trackSeed = 120, 1, 0

local function currentList()
  local c = library[cfg.folder]
  return c and c.tracks or {}
end
local function currentTrack() return currentList()[current] end

local function setVolume(v)
  cfg.volume = clamp01(v)
  if player then player:setVolume(cfg.volume) end
end

-- BPM automático: lido do nome (ex.: "128 bpm") ou gerado pelo hash do título
local function guessBpm(title)
  local n = tonumber(title:lower():match('(%d%d%d?)%s*bpm'))
  if n and n >= 60 and n <= 220 then return n end
  return 90 + hashStr(title) % 75
end

local function activeBpm()
  return (cfg.bpmManual and cfg.bpmManual >= 60) and cfg.bpmManual or trackBpm
end

local function playTrack(i)
  local list = currentList()
  if #list == 0 then return end
  current = ((i - 1) % #list) + 1
  local t = list[current]
  if player == nil then player = ui.MediaPlayer(t.path) else player:setSource(t.path) end
  player:setAutoPlay(true)
  player:setVolume(cfg.volume)
  player:play()
  state = 'playing'
  advanceLock = 1.0
  trackSeed = hashStr(t.title)
  trackBpm = guessBpm(t.title)
  trackPattern = 1 + trackSeed % 3
end

local function stopPlayback()
  if player then player:pause(); player:setCurrentTime(0) end
  state = 'stopped'
end

local function nextTrack(auto)
  local n = #currentList()
  if n == 0 then return end
  if auto and not cfg.repeatAll and not cfg.shuffle and current >= n then stopPlayback() return end
  if cfg.shuffle and n > 1 then
    local i = math.random(n)
    if i == current then i = i % n + 1 end
    playTrack(i)
  else
    playTrack(current + 1)
  end
end

local function prevTrack()
  if player and state ~= 'stopped' and player:currentTime() > 3 then
    player:setCurrentTime(0)
  else
    playTrack(current > 0 and current - 1 or #currentList())
  end
end

local function doPlay()
  if state == 'paused' and player then
    player:play(); state = 'playing'
  elseif state == 'stopped' or not player then
    local n = math.max(1, #currentList())
    playTrack(current > 0 and current or (cfg.shuffle and math.random(n) or 1))
  end
end

local function doPause()
  if state == 'playing' and player then player:pause(); state = 'paused'
  elseif state == 'paused' and player then player:play(); state = 'playing' end
end

local function togglePlay()
  if state == 'playing' then doPause() else doPlay() end
end

local function setFolder(i)
  cfg.folder, current = i, 0
  local n = #currentList()
  if n > 0 then playTrack(cfg.shuffle and math.random(n) or 1) end
end

local function stepFolder(d)
  local n = #library
  if n > 0 then setFolder((cfg.folder - 1 + d) % n + 1) end
end

--------------------------------------------------------------------------------
-- VISUALIZADOR PSEUDO-RÍTMICO
-- Simula bumbo / caixa / chimbal em passos de 16avos, com "energia" variando
-- a cada 4 compassos. Graves -> bumbo, médios -> caixa, agudos -> chimbal.
--------------------------------------------------------------------------------
local BARS = 24
local lvl, peak, peakHold = {}, {}, {}
local noisePh, noiseFr = {}, {}
for i = 1, BARS do
  lvl[i], peak[i], peakHold[i] = 0, 0, 0
  noisePh[i] = math.random() * 100
  noiseFr[i] = 1.5 + math.random() * 3.5
end

local beatPhase, ringAngle = 0, 0
local lastStep = -1
local kickEnv, snareEnv, hatEnv = 0, 0, 0
local energy, energyTarget = 0.8, 0.8

local function gauss(x, c, w) local d = (x - c) / w; return math.exp(-d * d) end

local function triggerStep(step)
  local s = step % 16
  local bar = math.floor(step / 16)
  local kick, snare, hat = false, false, 0

  if trackPattern == 1 then            -- eletrônico (4 por 4)
    kick  = (s % 4 == 0)
    snare = (s == 4 or s == 12)
    hat   = (s % 4 == 2) and 1 or ((s % 2 == 0) and 0.4 or 0.15)
  elseif trackPattern == 2 then        -- rock
    kick  = (s == 0 or s == 8 or (s == 10 and bar % 2 == 1))
    snare = (s == 4 or s == 12)
    hat   = (s % 2 == 0) and 0.8 or 0
  else                                 -- quebrado / hip-hop
    kick  = (s == 0 or s == 7 or s == 10 or (s == 14 and bar % 4 == 3))
    snare = (s == 4 or s == 12)
    hat   = (s % 2 == 0) and 0.7 or (math.random() < 0.5 and 0.35 or 0)
  end

  if bar % 4 == 3 and s >= 12 then snare = true end
  if not snare and math.random() < 0.06 then snare = true end

  if kick then kickEnv = 1 end
  if snare then snareEnv = (bar % 4 == 3 and s >= 12) and 1 or 0.9 end
  if hat > 0 then hatEnv = math.max(hatEnv, hat) end

  if s == 0 and bar % 4 == 0 then energyTarget = 0.55 + math.random() * 0.45 end
end

local function updateSpectrum(dt)
  local active = (state == 'playing')

  if active then
    beatPhase = beatPhase + dt * activeBpm() / 60
    local step = math.floor(beatPhase * 4)
    if step ~= lastStep then
      if lastStep < 0 or step - lastStep > 4 then lastStep = step - 1 end
      for st = lastStep + 1, step do triggerStep(st) end
      lastStep = step
    end
    energy = energy + (energyTarget - energy) * math.min(1, dt * 1.5)
  else
    lastStep = -1
  end

  kickEnv  = kickEnv  * math.exp(-dt * 7)
  snareEnv = snareEnv * math.exp(-dt * 9)
  hatEnv   = hatEnv   * math.exp(-dt * 16)

  local inten = cfg.intensity
  for i = 1, BARS do
    local target = 0
    if active then
      local f = (i - 1) / (BARS - 1)
      local wob = 0.5 + 0.5 * math.sin(clock * noiseFr[i] + noisePh[i])
      local v = kickEnv  * gauss(f, 0.10, 0.24) * 1.00
              + snareEnv * gauss(f, 0.42, 0.28) * 0.85
              + hatEnv   * gauss(f, 0.88, 0.26) * 0.80
              + wob * 0.22 * (1 - 0.4 * f)
              + 0.08 + math.random() * 0.05
      target = clamp01(v * (0.55 + 0.6 * energy) * inten)
    end

    if target > lvl[i] then
      lvl[i] = lvl[i] + (target - lvl[i]) * math.min(1, dt * 35)
    else
      lvl[i] = math.max(target, lvl[i] - dt * 1.8)
    end

    if lvl[i] >= peak[i] then
      peak[i], peakHold[i] = lvl[i], 0.35
    else
      peakHold[i] = peakHold[i] - dt
      if peakHold[i] < 0 then peak[i] = math.max(lvl[i], peak[i] - dt * 0.9) end
    end
  end
end

function script.update(dt)
  clock = clock + dt
  if advanceLock > 0 then advanceLock = advanceLock - dt end
  if player and state == 'playing' and advanceLock <= 0 then
    local dur = player:duration()
    if player:ended() or (dur > 1 and player:currentTime() >= dur - 0.15) then nextTrack(true) end
  end
  updateSpectrum(dt)
  if state == 'playing' then
    ringAngle = ringAngle + dt * (1.2 + 4 * (lvl[1] + lvl[2] + lvl[3]) / 3)
  end
end

--------------------------------------------------------------------------------
-- helpers de desenho (com escala)
-- Tudo é desenhado em coordenadas LOCAIS da janela (origem 0,0 = canto
-- superior esquerdo da janela, incluindo o padding).
--------------------------------------------------------------------------------
local DW, DH = 560, 190          -- dimensões de projeto do player
local SX, SY = 1, 1              -- escala atual
local OX, OY = 0, 0              -- origem do player dentro da janela
local BODY = { w = 560, h = 190 } -- tamanho total da janela (para o corpo)

local function P(x, y) return vec2(OX + x * SX, OY + y * SY) end

local function rect(x1, y1, x2, y2, col, r)
  ui.drawRectFilled(P(x1, y1), P(x2, y2), col, (r or 0) * SX)
end

local function border(x1, y1, x2, y2, col, th)
  ui.drawRect(P(x1, y1), P(x2, y2), col, 0, nil, math.max(0.6, (th or 1) * SX))
end

local function txt(s, size, x, y, col)
  ui.dwriteDrawText(s, size * SX, P(x, y), col)
end

local function ctext(s, size, cx, cy, col)
  local m = ui.measureDWriteText(s, size * SX)
  txt(s, size, cx - m.x / (2 * math.max(0.001, SX)), cy - m.y / (2 * math.max(0.001, SY)), col)
end

-- corpo do aparelho: preenche a janela inteira (cobre padding e faixas laterais)
local function fillBody(top, bot, highlight)
  ui.drawRectFilledMultiColor(vec2(0, 0), vec2(BODY.w, BODY.h), top, top, bot, bot)
  ui.drawLine(vec2(0, 1), vec2(BODY.w, 1), rgbm(1, 1, 1, highlight), 1)
end

local SEG = {
  ['0'] = 'abcdef', ['1'] = 'bc', ['2'] = 'abdeg', ['3'] = 'abcdg', ['4'] = 'bcfg',
  ['5'] = 'acdfg', ['6'] = 'acdefg', ['7'] = 'abc', ['8'] = 'abcdefg', ['9'] = 'abcdfg',
  ['-'] = 'g', [' '] = '',
}

local function drawDigit(ch, x, y, w, h, t)
  local mid = y + h / 2
  local R = {
    a = { x + t, y, x + w - t, y + t },
    b = { x + w - t, y + t, x + w, mid - t / 2 },
    c = { x + w - t, mid + t / 2, x + w, y + h - t },
    d = { x + t, y + h - t, x + w - t, y + h },
    e = { x, mid + t / 2, x + t, y + h - t },
    f = { x, y + t, x + t, mid - t / 2 },
    g = { x + t, mid - t / 2, x + w - t, mid + t / 2 },
  }
  local on = SEG[ch] or ''
  for name, r in pairs(R) do
    if on:find(name, 1, true) then
      rect(r[1] - 1.5, r[2] - 1.5, r[3] + 1.5, r[4] + 1.5, PAL.glow, 2)
      rect(r[1], r[2], r[3], r[4], PAL.on, 1)
    else
      rect(r[1], r[2], r[3], r[4], PAL.segOff, 1)
    end
  end
end

local function drawSeg7(text, x, y, dw, dh, t, gap)
  local cx = x
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == ':' then
      rect(cx + 3, y + dh * 0.28, cx + 3 + t, y + dh * 0.28 + t, PAL.on, 1)
      rect(cx + 3, y + dh * 0.72 - t, cx + 3 + t, y + dh * 0.72, PAL.on, 1)
      cx = cx + t + 7
    else
      drawDigit(ch, cx, y, dw, dh, t)
      cx = cx + dw + gap
    end
  end
end

-- L / PK opcionais (usados na pré-visualização da config)
local function drawSpectrum(x, y, w, h, segs, gap, L, PK)
  L, PK = L or lvl, PK or peak
  local bw = (w - gap * (BARS - 1)) / BARS
  local sh = (h - gap * (segs - 1)) / segs
  local g = grad(segs)
  for i = 1, BARS do
    local bx = x + (i - 1) * (bw + gap)
    local lit = math.floor(L[i] * segs + 0.5)
    local pk = math.floor(PK[i] * segs + 0.5)
    for s = 1, segs do
      local sy = y + h - s * sh - (s - 1) * gap
      local col = (s <= lit) and g[s] or ((s == pk and pk > 0) and PAL.peak or PAL.segOff)
      rect(bx, sy, bx + bw, sy + sh, col)
    end
  end
end

local function drawMarquee(msg, size, x1, y1, x2, y2, col)
  local full = msg .. '   ***   '
  local tw = ui.measureDWriteText(full, size).x
  ui.pushClipRect(P(x1, y1), P(x2, y2), true)
  if ui.measureDWriteText(msg, size).x > (x2 - x1) then
    local off = (clock * 45) % tw
    txt(full, size, x1 - off, y1, col)
    txt(full, size, x1 - off + tw, y1, col)
  else
    txt(msg, size, x1, y1, col)
  end
  ui.popClipRect()
end

local function btn(id, x, y, w, h, icon, lit)
  ui.setCursor(P(x, y))
  local clicked = ui.invisibleButton(id, vec2(w * SX, h * SY))
  local hov, act = ui.itemHovered(), ui.itemActive()
  local top = act and rgbm(0.07, 0.07, 0.10, 1) or (hov and rgbm(0.30, 0.28, 0.38, 1) or rgbm(0.21, 0.21, 0.27, 1))
  local bot = act and rgbm(0.13, 0.12, 0.17, 1) or rgbm(0.08, 0.08, 0.11, 1)
  ui.drawRectFilledMultiColor(P(x, y), P(x + w, y + h), top, top, bot, bot)
  border(x, y, x + w, y + h, lit and palA(0.95) or rgbm(0, 0, 0, 0.85), 2)
  icon(x + w / 2, y + h / 2, lit and PAL.text or rgbm(0.72, 0.68, 0.80, 1))
  return clicked
end

local function slider(id, x, y, w, h, value)
  ui.setCursor(P(x, y - 5))
  local released = ui.invisibleButton(id, vec2(w * SX, (h + 10) * SY))
  local active = ui.itemActive()
  local frac
  if active or released then
    local mx = (ui.mouseLocalPos().x - OX) / math.max(0.001, SX) - x
    frac = clamp01(mx / w)
  end
  local v = frac or value
  rect(x, y, x + w, y + h, rgbm(0.02, 0.02, 0.03, 1), 2)
  ui.drawRectFilledMultiColor(P(x, y), P(x + w * v, y + h), PAL.seekA, PAL.seekB, PAL.seekB, PAL.seekA)
  rect(x + w * v - 4, y - 3, x + w * v + 4, y + h + 3, rgbm(0.78, 0.76, 0.85, 1), 2)
  return frac, released, active
end

local function iconPlay(cx, cy, c)  ui.drawTriangleFilled(P(cx - 5, cy - 8), P(cx - 5, cy + 8), P(cx + 8, cy), c) end
local function iconPause(cx, cy, c) rect(cx - 6, cy - 7, cx - 2, cy + 7, c); rect(cx + 2, cy - 7, cx + 6, cy + 7, c) end
local function iconStop(cx, cy, c)  rect(cx - 6, cy - 6, cx + 6, cy + 6, c) end
local function iconPrev(cx, cy, c)  rect(cx - 8, cy - 7, cx - 6, cy + 7, c); ui.drawTriangleFilled(P(cx + 8, cy - 7), P(cx + 8, cy + 7), P(cx - 5, cy), c) end
local function iconNext(cx, cy, c)  rect(cx + 6, cy - 7, cx + 8, cy + 7, c); ui.drawTriangleFilled(P(cx - 8, cy - 7), P(cx - 8, cy + 7), P(cx + 5, cy), c) end
local function iconPlayPause(cx, cy, c)
  ui.drawTriangleFilled(P(cx - 10, cy - 6), P(cx - 10, cy + 6), P(cx - 1, cy), c)
  rect(cx + 2, cy - 6, cx + 5, cy + 6, c); rect(cx + 7, cy - 6, cx + 10, cy + 6, c)
end
local function iconDirPrev(cx, cy, c) ui.drawTriangleFilled(P(cx + 4, cy - 6), P(cx + 4, cy + 6), P(cx - 5, cy), c) end
local function iconDirNext(cx, cy, c) ui.drawTriangleFilled(P(cx - 4, cy - 6), P(cx - 4, cy + 6), P(cx + 5, cy), c) end
local function iconText(s) return function(cx, cy, c) ctext(s, 12, cx, cy, c) end end
local iconShuf, iconRep = iconText('SHUF'), iconText('REP')
local iconDirM, iconDirP = iconText('DIR-'), iconText('DIR+')

local function playbackTimes()
  if player and state ~= 'stopped' then return player:currentTime(), player:duration() end
  return 0, 0
end

local function marqueeText()
  local tr = currentTrack()
  if tr then return string.format('%02d. %s', current, tr.title):upper() end
  if #library == 0 then return ('SEM MUSICAS EM: ' .. cfg.root):upper() end
  return 'APERTE PLAY'
end

local function seekBar(x, y, w, h)
  local cur, dur = playbackTimes()
  local f, released = slider('seek', x, y, w, h, (dur > 0) and clamp01(cur / dur) or 0)
  if released and f and player and dur > 0 and state ~= 'stopped' then player:setCurrentTime(f * dur) end
end

local function timeDisplay(x, y, dw, dh, t, gap, hitW)
  local cur, dur = playbackTimes()
  local shown = cfg.showRemaining and math.max(0, dur - cur) or cur
  if cfg.showRemaining then rect(x - 12, y + dh / 2 - 2, x - 4, y + dh / 2 + 2, PAL.on, 1) end
  drawSeg7(fmtTime(shown), x, y, dw, dh, t, gap)
  ui.setCursor(P(x - 12, y - 2))
  if ui.invisibleButton('timeToggle', vec2(hitW * SX, (dh + 4) * SY)) then cfg.showRemaining = not cfg.showRemaining end
end

--------------------------------------------------------------------------------
-- SKIN 1: WINAMP
--------------------------------------------------------------------------------
local function drawWinamp()
  local tr, cat = currentTrack(), library[cfg.folder]

  fillBody(rgbm(0.17, 0.17, 0.21, 1), rgbm(0.04, 0.04, 0.06, 1), 0.12)

  ui.drawRectFilledMultiColor(P(12, 12), P(548, 116), PAL.dispTop, PAL.dispTop, PAL.dispBot, PAL.dispBot)
  border(12, 12, 548, 116, PAL.border, 2)
  for yy = 14, 114, 3 do ui.drawLine(P(13, yy), P(547, yy), rgbm(0, 0, 0, 0.20), math.max(1, SX)) end

  timeDisplay(34, 22, 20, 38, 5, 6, 130)

  txt(tr and tr.ext or '---', 13, 172, 22, tr and PAL.text or PAL.dim)
  txt(state == 'playing' and 'PLAY' or (state == 'paused' and 'PAUSE' or 'STOP'), 13, 212, 22, PAL.text)
  txt('SHUF', 13, 262, 22, cfg.shuffle and PAL.text or PAL.dim)
  txt('REP', 13, 304, 22, cfg.repeatAll and PAL.text or PAL.dim)
  txt('> ' .. (cat and cat.name:sub(1, 15) or 'SEM PASTA'), 15, 172, 44, PAL.on)
  if cat and current > 0 then txt(string.format('%03d/%03d', current, #cat.tracks), 13, 172, 64, PAL.dim) end
  txt(state == 'playing' and string.format('%d BPM', math.floor(activeBpm() + 0.5)) or 'EQ', 13, 246, 64,
      state == 'playing' and PAL.text or PAL.dim)

  drawSpectrum(332, 20, 204, 56, 12, 2)

  rect(20, 84, 540, 110, rgbm(0, 0, 0, 0.35), 2)
  drawMarquee(marqueeText(), 18, 24, 88, 536, 110, PAL.text)

  seekBar(12, 124, 536, 8)

  local by = 142
  if btn('prev', 12, by, 44, 34, iconPrev) then prevTrack() end
  if btn('play', 62, by, 44, 34, iconPlay, state == 'playing') then doPlay() end
  if btn('pause', 112, by, 44, 34, iconPause, state == 'paused') then doPause() end
  if btn('stop', 162, by, 44, 34, iconStop, state == 'stopped') then stopPlayback() end
  if btn('next', 212, by, 44, 34, iconNext) then nextTrack(false) end
  if btn('shuf', 272, by, 44, 34, iconShuf, cfg.shuffle) then cfg.shuffle = not cfg.shuffle end
  if btn('rep', 322, by, 44, 34, iconRep, cfg.repeatAll) then cfg.repeatAll = not cfg.repeatAll end
  if btn('dirP', 382, by, 34, 34, iconDirPrev) then stepFolder(-1) end
  if btn('dirN', 422, by, 34, 34, iconDirNext) then stepFolder(1) end

  txt('VOL', 11, 470, 140, PAL.dim)
  local vf, _, vActive = slider('vol', 470, 160, 78, 8, cfg.volume)
  if vf and vActive then setVolume(vf) end
end

--------------------------------------------------------------------------------
-- SKIN 2: RÁDIO AUTOMOTIVO
--------------------------------------------------------------------------------
local knobDrag = 0

local function drawKnob(cx, cy, r)
  local R = r * SX
  for k = 1, 5 do ui.drawCircleFilled(P(cx, cy), (r + 15 - k * 2.5) * SX, palA(0.05 + 0.03 * k), 48) end
  ui.drawCircle(P(cx, cy), (r + 3) * SX, palA(0.95), 48, math.max(1, 2.5 * SX))
  ui.drawCircleFilled(P(cx, cy), R, rgbm(0.09, 0.09, 0.11, 1), 48)
  for k = 1, 7 do
    local g = 0.13 + 0.05 * (k % 2)
    ui.drawCircle(P(cx, cy), r * k / 8 * SX, rgbm(g, g, g + 0.02, 1), 40, math.max(0.6, 1.2 * SX))
  end
  ui.drawCircleFilled(P(cx - r * 0.28, cy - r * 0.32), r * 0.38 * SX, rgbm(1, 1, 1, 0.05), 24)

  local leds = 21
  for i = 0, leds - 1 do
    local f = i / (leds - 1)
    local a = math.rad(135 + 270 * f)
    ui.drawCircleFilled(P(cx + math.cos(a) * (r + 10), cy + math.sin(a) * (r + 10)), math.max(1, 2 * SX),
      (f <= cfg.volume + 1e-4) and PAL.on or PAL.segOff, 8)
  end
  local a = math.rad(135 + 270 * cfg.volume)
  ui.drawLine(P(cx + math.cos(a) * r * 0.35, cy + math.sin(a) * r * 0.35),
              P(cx + math.cos(a) * r * 0.85, cy + math.sin(a) * r * 0.85), PAL.on, math.max(1, 3 * SX))

  -- arrastar/roda do mouse = volume | clique = play/pause
  ui.setCursor(P(cx - r, cy - r))
  local clicked = ui.invisibleButton('knob', vec2(r * 2 * SX, r * 2 * SY))
  local act, hov = ui.itemActive(), ui.itemHovered()
  if hov then
    local wh = ui.mouseWheel()
    if wh ~= 0 then setVolume(cfg.volume + wh * 0.05) end
  end
  if act then
    local d = ui.mouseDelta()
    knobDrag = knobDrag + math.abs(d.x) + math.abs(d.y)
    setVolume(cfg.volume + (d.x - d.y) * 0.005 / math.max(0.2, SX))
  end
  if clicked then
    if knobDrag < 4 * SX then togglePlay() end
    knobDrag = 0
  elseif not act then
    knobDrag = 0
  end
end

local function drawRing(cx, cy, r, pulse)
  local dots = 18
  for i = 0, dots - 1 do
    local a = ringAngle + i * (math.pi * 2 / dots)
    ui.drawCircleFilled(P(cx + math.cos(a) * r, cy + math.sin(a) * r), math.max(1, 1.6 * SX),
      (i % 3 == 0) and PAL.on or PAL.dim, 8)
  end
  for i = 0, 11 do
    local a = -ringAngle * 0.6 + i * (math.pi * 2 / 12)
    ui.drawCircleFilled(P(cx + math.cos(a) * r * 0.66, cy + math.sin(a) * r * 0.66), math.max(1, 1.2 * SX), PAL.dim, 6)
  end
  local rr = r * (0.22 + 0.2 * pulse)
  ui.drawCircleFilled(P(cx, cy), (rr + 3) * SX, PAL.glow, 16)
  ui.drawCircle(P(cx, cy), rr * SX, PAL.on, 20, math.max(1, 1.5 * SX))
end

local function drawRadio()
  local tr, cat = currentTrack(), library[cfg.folder]

  fillBody(rgbm(0.11, 0.11, 0.13, 1), rgbm(0.02, 0.02, 0.03, 1), 0.10)

  drawKnob(68, 82, 38)
  txt(string.format('VOL %02d', math.floor(cfg.volume * 99 + 0.5)), 11, 44, 142, PAL.text)
  txt('PUSH: PLAY/PAUSE', 9, 22, 162, PAL.dim)

  ui.drawRectFilledMultiColor(P(128, 12), P(548, 126), PAL.dispTop, PAL.dispTop, PAL.dispBot, PAL.dispBot)
  ui.drawRectFilledMultiColor(P(128, 12), P(548, 50),
    rgbm(1, 1, 1, 0.05), rgbm(1, 1, 1, 0.05), rgbm(1, 1, 1, 0), rgbm(1, 1, 1, 0))
  border(128, 12, 548, 126, rgbm(0, 0, 0, 1), 2)

  drawRing(166, 54, 24, (lvl[1] + lvl[2] + lvl[3] + lvl[4]) / 4)
  drawRing(510, 54, 24, (lvl[BARS] + lvl[BARS - 1] + lvl[BARS - 2]) / 3)
  txt(tr and tr.ext or '---', 10, 154, 84, tr and PAL.text or PAL.dim)
  txt('USB', 10, 499, 84, tr and PAL.text or PAL.dim)

  drawMarquee(marqueeText(), 13, 202, 16, 474, 34, PAL.text)

  drawSeg7(current > 0 and string.format('%02d', current % 100) or '--', 204, 42, 15, 30, 4, 5)
  timeDisplay(258, 38, 21, 38, 5, 6, 132)

  txt(state == 'playing' and 'PLAY' or (state == 'paused' and 'PAUSE' or 'STOP'), 11, 398, 40, PAL.text)
  txt('SHUF', 11, 398, 54, cfg.shuffle and PAL.text or PAL.dim)
  txt('REP', 11, 438, 54, cfg.repeatAll and PAL.text or PAL.dim)
  txt('EQ', 11, 398, 68, state == 'playing' and PAL.text or PAL.dim)
  if cat and current > 0 then txt(string.format('%d/%d', current, #cat.tracks), 10, 430, 68, PAL.dim) end
  txt('> ' .. (cat and cat.name:sub(1, 30) or 'SEM PASTA'), 12, 202, 86, PAL.on)

  drawSpectrum(140, 104, 396, 18, 6, 3)

  seekBar(128, 132, 420, 4)

  local defs = {
    { 'r_prev', iconPrev, false, prevTrack },
    { 'r_next', iconNext, false, function() nextTrack(false) end },
    { 'r_pp', iconPlayPause, state == 'playing', togglePlay },
    { 'r_stop', iconStop, state == 'stopped', stopPlayback },
    { 'r_shuf', iconShuf, cfg.shuffle, function() cfg.shuffle = not cfg.shuffle end },
    { 'r_rep', iconRep, cfg.repeatAll, function() cfg.repeatAll = not cfg.repeatAll end },
    { 'r_dirm', iconDirM, false, function() stepFolder(-1) end },
    { 'r_dirp', iconDirP, false, function() stepFolder(1) end },
  }
  for i, d in ipairs(defs) do
    local x = 128 + (i - 1) * 53
    if btn(d[1], x, 144, 48, 34, d[2], d[3]) then d[4]() end
    txt(tostring(i), 9, x + 3, 146, PAL.dim)
  end
end

--------------------------------------------------------------------------------
-- JANELA PRINCIPAL (responsiva, corpo preenche a janela inteira)
--------------------------------------------------------------------------------
function script.windowMain(dt)
  updatePalette()

  -- tamanho total da janela (inclui padding). Fallback: espaço disponível.
  local winW, winH = DW, DH
  local ok, sz = pcall(function() return ui.windowSize() end)
  if ok and sz and type(sz.x) == 'number' and sz.x > 1 and sz.y > 1 then
    winW, winH = sz.x, sz.y
  else
    local okw, aw = pcall(function() return ui.availableSpaceX() end)
    local okh, ah = pcall(function() return ui.availableSpaceY() end)
    if okw and type(aw) == 'number' and aw > 1 then winW = aw end
    if okh and type(ah) == 'number' and ah > 1 then winH = ah end
  end

  BODY.w, BODY.h = winW, winH

  -- escala uniforme + centralização na janela inteira (origem em 0,0)
  local s = math.max(math.min(winW / DW, winH / DH), 0.15)
  SX, SY = s, s
  OX = (winW - DW * s) * 0.5
  OY = (winH - DH * s) * 0.5

  -- amplia a área de recorte para a janela toda (senão o padding é cortado)
  pcall(ui.pushClipRect, vec2(0, 0), vec2(winW, winH), false)

  ui.pushDWriteFont('Consolas')
  if cfg.skin == 2 then drawRadio() else drawWinamp() end
  ui.popDWriteFont()

  pcall(ui.popClipRect)

  ui.setCursor(vec2(0, 0))
  ui.dummy(vec2(1, 1))
end

--------------------------------------------------------------------------------
-- JANELA DA PLAYLIST
--------------------------------------------------------------------------------
function script.windowPlaylist(dt)
  ui.text('Pasta principal:')
  ui.setNextItemWidth(ui.availableSpaceX() - 90)
  local v = ui.inputText('##root', cfg.root)
  if v ~= cfg.root then cfg.root = v end
  ui.sameLine()
  if ui.button('Escanear') then rescan() end

  local cat = library[cfg.folder]
  ui.text('Estacao:')
  ui.sameLine()
  ui.combo('##cat', cat and (cat.name .. ' (' .. #cat.tracks .. ')') or 'nenhuma pasta com musicas', function()
    for i, c in ipairs(library) do
      if ui.selectable(c.name .. ' (' .. #c.tracks .. ')', i == cfg.folder) then setFolder(i) end
    end
  end)

  ui.separator()
  for i, t in ipairs(currentList()) do
    ui.pushID(i)
    local label = string.format('%s%03d  %s  [%s]', (i == current and state ~= 'stopped') and '> ' or '  ', i, t.title, t.ext)
    if ui.selectable(label, i == current) then playTrack(i) end
    ui.popID()
  end
end

--------------------------------------------------------------------------------
-- JANELA DE CONFIGURAÇÃO (tema, cor, pulso)
--------------------------------------------------------------------------------
local PRESETS = {
  { 'Roxo', 209, 115, 255 }, { 'Azul', 70, 150, 255 }, { 'Vermelho', 255, 70, 90 },
  { 'Verde', 70, 255, 120 }, { 'Ambar', 255, 170, 40 }, { 'Ciano', 60, 230, 255 },
}

local demoL, demoP = {}, {}

function script.windowConfig(dt)
  updatePalette()
  local w = ui.availableSpaceX()
  local v, ch

  ui.text('TEMA')
  if ui.radioButton('Winamp', cfg.skin == 1) then cfg.skin = 1 end
  ui.sameLine()
  if ui.radioButton('Radio automotivo', cfg.skin == 2) then cfg.skin = 2 end

  ui.separator()
  ui.text('COR (RGB + saturacao)')
  ui.setNextItemWidth(w); v, ch = ui.slider('##colR', cfg.colR, 0, 255, 'R: %.0f'); if ch then cfg.colR = math.floor(v + 0.5) end
  ui.setNextItemWidth(w); v, ch = ui.slider('##colG', cfg.colG, 0, 255, 'G: %.0f'); if ch then cfg.colG = math.floor(v + 0.5) end
  ui.setNextItemWidth(w); v, ch = ui.slider('##colB', cfg.colB, 0, 255, 'B: %.0f'); if ch then cfg.colB = math.floor(v + 0.5) end
  ui.setNextItemWidth(w); v, ch = ui.slider('##sat', cfg.sat * 100, 0, 200, 'Saturacao: %.0f%%'); if ch then cfg.sat = v / 100 end
  ui.setNextItemWidth(w); v, ch = ui.slider('##bri', cfg.bright * 100, 30, 150, 'Brilho: %.0f%%'); if ch then cfg.bright = v / 100 end

  for i, p in ipairs(PRESETS) do
    if (i - 1) % 3 ~= 0 then ui.sameLine() end
    if ui.button(p[1], vec2((w - 16) / 3, 0)) then
      cfg.colR, cfg.colG, cfg.colB, cfg.sat, cfg.bright = p[2], p[3], p[4], 1, 1
    end
  end
  if ui.button('Display branco (saturacao 0%)', vec2(w, 0)) then cfg.sat = 0 end

  updatePalette()
  local hh, ss, vv = rgb2hsv(cfg.colR / 255, cfg.colG / 255, cfg.colB / 255)
  ui.text(string.format('Base: H %.0f  S %.0f%%  V %.0f%%   ->  final S %.0f%%  V %.0f%%',
    hh * 360, ss * 100, vv * 100, PAL.s * 100, PAL.v * 100))

  -- pré-visualização ao vivo (animação própria, independe do player)
  for i = 1, BARS do
    local val = 0.5 + 0.5 * math.sin(clock * (1.5 + i * 0.37) + i)
    demoL[i] = val * (1 - 0.5 * (i - 1) / BARS)
    demoP[i] = math.min(1, demoL[i] + 0.12)
  end

  -- usa escala 1 e origem no cursor, sem herdar a escala do player
  local o = ui.getCursor()
  local sSX, sSY, sOX, sOY = SX, SY, OX, OY
  SX, SY = 1, 1
  OX, OY = o.x, o.y
  ui.drawRectFilledMultiColor(P(0, 0), P(w, 64), PAL.dispTop, PAL.dispTop, PAL.dispBot, PAL.dispBot)
  border(0, 0, w, 64, PAL.border, 1)
  drawSeg7('12:34', 10, 14, 14, 28, 4, 4)
  drawSpectrum(w * 0.42, 8, w * 0.58 - 10, 48, 10, 2, demoL, demoP)
  SX, SY, OX, OY = sSX, sSY, sOX, sOY
  ui.setCursor(o)
  ui.dummy(vec2(w, 70))

  ui.separator()
  ui.text('PULSO DO VISUALIZADOR')
  ui.setNextItemWidth(w)
  v, ch = ui.slider('##bpm', cfg.bpmManual, 0, 200, cfg.bpmManual < 60 and 'BPM: automatico' or 'BPM: %.0f')
  if ch then cfg.bpmManual = (v < 60) and 0 or math.floor(v + 0.5) end
  ui.setNextItemWidth(w)
  v, ch = ui.slider('##int', cfg.intensity * 100, 30, 150, 'Intensidade: %.0f%%')
  if ch then cfg.intensity = v / 100 end
  ui.textWrapped('BPM automatico: usa "128 bpm" do nome do arquivo, se existir; senao gera um valor fixo por faixa. Abaixo de 60 = automatico.')
end

--------------------------------------------------------------------------------
-- inicialização
--------------------------------------------------------------------------------
rescan()
updatePalette()