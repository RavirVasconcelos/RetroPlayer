--------------------------------------------------------------------------------
-- RETRO PLAYER v4.4 - app Lua (CSP) para Assetto Corsa
-- 5 Skins: Winamp | Rádio | BZR Studio | AIMP Deck | Midnight X-AMP (Summit)
-- Espectro Real FFT via FFmpeg (v4.1) + Fallback Pseudo-Rítmico (v3.2)
-- MP3/M4A/AAC/WAV | estações por pasta | cor RGB + saturação + brilho
-- Janela 100% responsiva (escala automática preservando proporção)
--------------------------------------------------------------------------------

local EXTENSIONS = { mp3 = true, m4a = true, wav = true, aac = true }
local BARS = 24

--------------------------------------------------------------------------------
-- utilidades e caminhos
--------------------------------------------------------------------------------
local function safe(f)
  local ok, r = pcall(f)
  if ok then return r end
  return nil
end

local function log(m)
  pcall(ac.log, 'RetroPlayer: ' .. tostring(m))
end

local function clamp(x, a, b)
  if x < a then return a elseif x > b then return b end
  return x
end

local function clamp01(v)
  return math.max(0, math.min(1, v))
end

local function dirExists(p)
  if io.dirExists then
    local ok, r = pcall(io.dirExists, p)
    if ok then return r and true or false end
  end
  if io.isDirectory then
    local ok, r = pcall(io.isDirectory, p)
    if ok then return r and true or false end
  end
  return false
end

local function fileExists(p)
  if not p or p == '' then return false end
  if io.fileExists then
    local ok, r = pcall(io.fileExists, p)
    if ok then return r and true or false end
  end
  local ok, r = pcall(io.getAttributes, p)
  return ok and r ~= nil and r ~= false
end

local function normPath(p)
  p = tostring(p or ''):gsub('\\', '/')
  p = p:gsub('/+$', '')
  return p
end

local function rootFolder()
  local p = safe(function() return ac.getFolder(ac.FolderID.Root) end)
  return (p and p ~= '') and p or 'C:'
end

local AC_ROOT = normPath(rootFolder())
local APP_DIR = safe(function() return ac.getFolder(ac.FolderID.ScriptOrigin) end)
if not APP_DIR or APP_DIR == '' or not dirExists(APP_DIR) then
  local apps = safe(function() return ac.getFolder(ac.FolderID.ACApps) end) or (AC_ROOT .. '/apps')
  APP_DIR = apps .. '/lua/RetroPlayer'
end
APP_DIR = normPath(APP_DIR)
local CACHE = APP_DIR .. '/cache'

-- Opcional: se existir midnight_summit.png na pasta do app, usa também na Skin 5
local LOGO_PNG = APP_DIR .. '/midnight_summit.png'
local hasLogoPng = fileExists(LOGO_PNG)

local cfg = ac.storage{
  root = rootFolder() .. '\\music',
  volume = 0.7,
  shuffle = false,
  repeatAll = true,
  folder = 1,
  showRemaining = false,
  skin = 1,                 -- 1=Winamp, 2=Rádio, 3=BZR Studio, 4=AIMP Deck, 5=Midnight X-AMP
  colR = 209, colG = 115, colB = 255,
  sat = 1.0,                -- multiplicador de saturação (0..2)
  bright = 1.0,             -- multiplicador de brilho (0.3..1.5)
  bpmManual = 0,            -- 0 = automático
  intensity = 1.0,          -- intensidade do pulso (0.3..1.5)
  realSpectrum = true,      -- usa FFT via ffmpeg quando disponível
  ffmpeg = APP_DIR .. '/bin/ffmpeg.exe',
  sensitivity = 6,          -- ganho em dB do espectro real
  eqPreset = 1,             -- preset visual (AIMP / BZR)
}

local function hashStr(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 1000003 end
  return h
end

local function fmtTime(t)
  t = math.max(0, math.floor(t))
  return string.format('%02d:%02d', math.min(99, math.floor(t / 60)), t % 60)
end

local function fmtTimeLong(t)
  t = math.max(0, math.floor(t))
  local h = math.floor(t / 3600)
  local m = math.floor((t % 3600) / 60)
  local s = t % 60
  return string.format('%02d:%02d:%02d', math.min(99, h), m, s)
end

local function fmtTimeSonique(t)
  t = math.max(0, t or 0)
  local m = math.min(99, math.floor(t / 60))
  local s = math.floor(t % 60)
  local cs = math.floor((t * 100) % 100)
  return string.format('00:%02d:%02d.%02d', m, s, cs)
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

  -- Cores do visor LCD retroiluminado (Skin 3: BZR Studio)
  PAL.lcdTop   = hsv(h, clamp01(s * 0.46), clamp01(0.56 + v * 0.24))
  PAL.lcdBot   = hsv(h, clamp01(s * 0.54), clamp01(0.46 + v * 0.20))
  PAL.lcdInk   = hsv(h, clamp01(s * 0.90), 0.09)
  PAL.lcdMid   = hsv(h, clamp01(s * 0.80), 0.22, 0.85)
  PAL.lcdGhost = hsv(h, clamp01(s * 0.55), 0.38, 0.24)

  -- Cores de destaque metálico/botões (Skin 4: AIMP Deck)
  PAL.aimpBtnHi = hsv(h, clamp01(s * 0.85), clamp01(math.max(0.65, v)))
  PAL.aimpBtnLo = hsv(h, clamp01(s * 1.10), clamp01(math.max(0.35, v * 0.58)))

  -- Onda complementar estilo Sonique (Skin 5: Midnight X-AMP)
  PAL.wave2 = hsv((h + 0.38) % 1.0, clamp01(math.max(0.45, s)), clamp01(v * 0.95), 0.80)
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
-- MOTOR FFT + ANÁLISE FFMPEG (v4.1)
--------------------------------------------------------------------------------
local N, SR = 1024, 11025
local RE, IM, WIN, REV, COS, SIN = {}, {}, {}, {}, {}, {}
local BLO, BHI, TILT = {}, {}, {}
local pcm = { status = 'idle', data = nil, token = 0, msg = '' }

local function initFFT()
  local bits = 10
  for i = 0, N - 1 do
    local r, x = 0, i
    for _ = 1, bits do r = r * 2 + (x % 2); x = math.floor(x / 2) end
    REV[i] = r
    WIN[i + 1] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (N - 1))
    RE[i + 1] = 0
    IM[i + 1] = 0
  end
  for k = 0, N / 2 - 1 do
    COS[k + 1] = math.cos(2 * math.pi * k / N)
    SIN[k + 1] = -math.sin(2 * math.pi * k / N)
  end
  local fmin, fmax = 50, 5000
  for b = 1, BARS do
    local f0 = fmin * (fmax / fmin) ^ ((b - 1) / BARS)
    local f1 = fmin * (fmax / fmin) ^ (b / BARS)
    local k0 = math.max(1, math.floor(f0 * N / SR + 0.5))
    local k1 = math.max(k0, math.floor(f1 * N / SR))
    BLO[b], BHI[b] = k0, k1
    TILT[b] = 3 * math.log(math.sqrt(f0 * f1) / 50) / math.log(2)
  end
end

local function fftRun()
  local size = 2
  while size <= N do
    local half = size / 2
    local step = N / size
    for start = 0, N - 1, size do
      local k = 0
      for j = start, start + half - 1 do
        local wr, wi = COS[k + 1], SIN[k + 1]
        local a, b = j + 1, j + half + 1
        local xr, xi = RE[b], IM[b]
        local tr = xr * wr - xi * wi
        local ti = xr * wi + xi * wr
        RE[b] = RE[a] - tr; IM[b] = IM[a] - ti
        RE[a] = RE[a] + tr; IM[a] = IM[a] + ti
        k = k + step
      end
    end
    size = size * 2
  end
end

local function startAnalysis(tr)
  pcm.token = pcm.token + 1
  pcm.data = nil
  pcm.msg = ''
  local token = pcm.token
  if not cfg.realSpectrum then pcm.status = 'off'; return end
  if not tr or not tr.path then pcm.status = 'idle'; return end
  if not fileExists(cfg.ffmpeg) then pcm.status = 'missing'; return end

  pcm.status = 'decoding'
  pcall(io.createDir, CACHE)
  local out = CACHE .. '/track_' .. token .. '.pcm'

  local ok, e = pcall(function()
    os.runConsoleProcess({
      filename = cfg.ffmpeg,
      arguments = {
        '-hide_banner', '-v', 'error', '-y',
        '-i', tr.path, '-vn',
        '-ac', '1', '-ar', tostring(SR), '-f', 's16le', out
      },
      workingDirectory = APP_DIR,
    }, function(err, data)
      if token ~= pcm.token then pcall(io.deleteFile, out); return end
      local s = safe(function() return io.load(out) end)
      if type(s) == 'string' and #s > N * 4 then
        pcm.data = s
        pcm.status = 'ready'
      else
        pcm.status = 'error'
        local m = err and tostring(err) or ''
        if type(data) == 'table' then m = m .. ' ' .. tostring(data.stderr or data.stdout or '') end
        pcm.msg = m
        log('ffmpeg falhou: ' .. m)
      end
      pcall(io.deleteFile, out)
    end)
  end)

  if not ok then
    pcm.status = 'error'
    pcm.msg = tostring(e)
    log('runConsoleProcess: ' .. tostring(e))
  end
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
  local items = safe(function() return io.scanDir(dir, '*') end) or {}
  table.sort(items, function(a, b) return a:lower() < b:lower() end)
  return items
end

local function collect(dir, list, depth)
  for _, name in ipairs(sortedItems(dir)) do
    if name ~= '.' and name ~= '..' then
      local full = dir .. '\\' .. name
      if dirExists(full) then
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
  if not dirExists(root) then pcall(io.createDir, root) end
  if dirExists(root) then
    for _, name in ipairs(sortedItems(root)) do
      if name ~= '.' and name ~= '..' then
        local full = root .. '\\' .. name
        if dirExists(full) then
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

local function currentTrack()
  return currentList()[current]
end

local function playbackTimes()
  if player and state ~= 'stopped' then
    local ok, t, d = pcall(function() return player:currentTime(), player:duration() end)
    if ok then return t or 0, d or 0 end
  end
  return 0, 0
end

local function setVolume(v)
  cfg.volume = clamp01(v)
  if player then pcall(function() player:setVolume(cfg.volume) end) end
end

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
  startAnalysis(t)
end

local function stopPlayback()
  if player then pcall(function() player:pause(); player:setCurrentTime(0) end) end
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
  local curT = playbackTimes()
  if player and state ~= 'stopped' and curT > 3 then
    pcall(function() player:setCurrentTime(0) end)
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
-- VISUALIZADOR (FFT Real + Fallback Pseudo-Rítmico da v3.2)
--------------------------------------------------------------------------------
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

  if trackPattern == 1 then             -- eletrônico (4 por 4)
    kick  = (s % 4 == 0)
    snare = (s == 4 or s == 12)
    hat   = (s % 4 == 2) and 1 or ((s % 2 == 0) and 0.4 or 0.15)
  elseif trackPattern == 2 then         -- rock
    kick  = (s == 0 or s == 8 or (s == 10 and bar % 2 == 1))
    snare = (s == 4 or s == 12)
    hat   = (s % 2 == 0) and 0.8 or 0
  else                                  -- quebrado / hip-hop
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

local function applyBarSmoothing(i, target, dt)
  if target > lvl[i] then
    lvl[i] = lvl[i] + (target - lvl[i]) * math.min(1, dt * 35)
  else
    lvl[i] = math.max(target, lvl[i] - dt * 2.2)
  end

  if lvl[i] >= peak[i] then
    peak[i], peakHold[i] = lvl[i], 0.35
  else
    peakHold[i] = peakHold[i] - dt
    if peakHold[i] < 0 then peak[i] = math.max(lvl[i], peak[i] - dt * 0.9) end
  end
end

local function updateRealFFT(t, dt)
  local s = pcm.data
  local total = math.floor(#s / 2)
  local start = math.floor(t * SR) - math.floor(N / 2)
  if start < 0 then start = 0 end
  if start + N > total then
    for i = 1, BARS do applyBarSmoothing(i, 0, dt) end
    return
  end

  local bt = { s:byte(start * 2 + 1, (start + N) * 2) }
  for i = 0, N - 1 do
    local v = (bt[2 * i + 1] or 0) + (bt[2 * i + 2] or 0) * 256
    if v >= 32768 then v = v - 65536 end
    local r = REV[i] + 1
    RE[r] = v / 32768 * WIN[i + 1]
    IM[r] = 0
  end

  fftRun()

  local sens = cfg.sensitivity
  local norm = 4 / N
  for b = 1, BARS do
    local m = 0
    for k = BLO[b], BHI[b] do
      local re, im = RE[k + 1], IM[k + 1]
      local a = re * re + im * im
      if a > m then m = a end
    end
    local amp = math.sqrt(m) * norm
    local db = 20 * math.log10(amp + 1e-9) + TILT[b] + sens
    local target = clamp01((db + 48) / 42)
    applyBarSmoothing(b, target, dt)
  end
end

local function updateSpectrum(dt)
  local active = (state == 'playing')

  if active and cfg.realSpectrum and pcm.status == 'ready' and pcm.data then
    local curT = playbackTimes()
    updateRealFFT(curT, dt)
    return
  end

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
    applyBarSmoothing(i, target, dt)
  end
end

function script.update(dt)
  clock = clock + dt
  if advanceLock > 0 then advanceLock = advanceLock - dt end
  if player and state == 'playing' and advanceLock <= 0 then
    local curT, dur = playbackTimes()
    local ended = safe(function() return player:ended() end)
    if ended or (dur > 1 and curT >= dur - 0.15) then nextTrack(true) end
  end
  updateSpectrum(dt)
  if state == 'playing' then
    ringAngle = ringAngle + dt * (1.2 + 4 * (lvl[1] + lvl[2] + lvl[3]) / 3)
  end
end

--------------------------------------------------------------------------------
-- helpers de desenho (com escala)
--------------------------------------------------------------------------------
local DW, DH = 560, 190           -- dimensões de projeto do player
local SX, SY = 1, 1               -- escala atual
local OX, OY = 0, 0               -- origem do player dentro da janela
local BODY = { w = 560, h = 190 } -- tamanho total da janela (para o corpo)

local function P(x, y) return vec2(OX + x * SX, OY + y * SY) end

local function rect(x1, y1, x2, y2, col, r)
  ui.drawRectFilled(P(x1, y1), P(x2, y2), col, (r or 0) * SX)
end

local function border(x1, y1, x2, y2, col, th, r)
  ui.drawRect(P(x1, y1), P(x2, y2), col, (r or 0) * SX, nil, math.max(0.6, (th or 1) * SX))
end

local function txt(s, size, x, y, col)
  ui.dwriteDrawText(s, size * SX, P(x, y), col)
end

local function ctext(s, size, cx, cy, col)
  local m = ui.measureDWriteText(s, size * SX)
  txt(s, size, cx - m.x / (2 * math.max(0.001, SX)), cy - m.y / (2 * math.max(0.001, SY)), col)
end

local function fillBody(top, bot, highlight)
  ui.drawRectFilledMultiColor(vec2(0, 0), vec2(BODY.w, BODY.h), top, top, bot, bot)
  ui.drawLine(vec2(0, 1), vec2(BODY.w, 1), rgbm(1, 1, 1, highlight), 1)
end

local SEG = {
  ['0'] = 'abcdef', ['1'] = 'bc', ['2'] = 'abdeg', ['3'] = 'abcdg', ['4'] = 'bcfg',
  ['5'] = 'acdfg', ['6'] = 'acdefg', ['7'] = 'abc', ['8'] = 'abcdefg', ['9'] = 'abcdfg',
  ['-'] = 'g', [' '] = '',
}

local function drawDigitCustom(ch, x, y, w, h, t, colOn, colOff, colGlow)
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
      if colGlow then
        rect(r[1] - 1.5, r[2] - 1.5, r[3] + 1.5, r[4] + 1.5, colGlow, 2)
      end
      rect(r[1], r[2], r[3], r[4], colOn, 1)
    elseif colOff then
      rect(r[1], r[2], r[3], r[4], colOff, 1)
    end
  end
end

local function drawSeg7Custom(text, x, y, dw, dh, t, gap, colOn, colOff, colGlow)
  local cx = x
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == ':' then
      rect(cx + 3, y + dh * 0.28, cx + 3 + t, y + dh * 0.28 + t, colOn, 1)
      rect(cx + 3, y + dh * 0.72 - t, cx + 3 + t, y + dh * 0.72, colOn, 1)
      cx = cx + t + 7
    else
      drawDigitCustom(ch, cx, y, dw, dh, t, colOn, colOff, colGlow)
      cx = cx + dw + gap
    end
  end
end

local function drawSeg7(text, x, y, dw, dh, t, gap)
  drawSeg7Custom(text, x, y, dw, dh, t, gap, PAL.on, PAL.segOff, PAL.glow)
end

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
local function iconFastRew(cx, cy, c)
  ui.drawTriangleFilled(P(cx, cy - 5), P(cx, cy + 5), P(cx - 7, cy), c)
  ui.drawTriangleFilled(P(cx + 7, cy - 5), P(cx + 7, cy + 5), P(cx, cy), c)
end
local function iconFastFwd(cx, cy, c)
  ui.drawTriangleFilled(P(cx - 7, cy - 5), P(cx - 7, cy + 5), P(cx, cy), c)
  ui.drawTriangleFilled(P(cx, cy - 5), P(cx, cy + 5), P(cx + 7, cy), c)
end
local function iconEject(cx, cy, c)
  ui.drawTriangleFilled(P(cx, cy - 6), P(cx - 6, cy + 1), P(cx + 6, cy + 1), c)
  rect(cx - 6, cy + 3, cx + 6, cy + 6, c)
end
local function iconText(s, sz) return function(cx, cy, c) ctext(s, sz or 12, cx, cy, c) end end
local iconShuf, iconRep = iconText('SHUF'), iconText('REP')
local iconDirM, iconDirP = iconText('DIR-'), iconText('DIR+')

local function marqueeText()
  local tr = currentTrack()
  if tr then return string.format('%02d. %s', current, tr.title):upper() end
  if #library == 0 then return ('SEM MUSICAS EM: ' .. cfg.root):upper() end
  return 'APERTE PLAY'
end

local function seekBar(x, y, w, h)
  local cur, dur = playbackTimes()
  local f, released = slider('seek', x, y, w, h, (dur > 0) and clamp01(cur / dur) or 0)
  if released and f and player and dur > 0 and state ~= 'stopped' then
    pcall(function() player:setCurrentTime(f * dur) end)
  end
end

local function timeDisplay(x, y, dw, dh, t, gap, hitW)
  local cur, dur = playbackTimes()
  local shown = cfg.showRemaining and math.max(0, dur - cur) or cur
  if cfg.showRemaining then rect(x - 12, y + dh / 2 - 2, x - 4, y + dh / 2 + 2, PAL.on, 1) end
  drawSeg7(fmtTime(shown), x, y, dw, dh, t, gap)
  ui.setCursor(P(x - 12, y - 2))
  if ui.invisibleButton('timeToggle', vec2(hitW * SX, (dh + 4) * SY)) then cfg.showRemaining = not cfg.showRemaining end
end

local function eqModeText(winampStyle)
  if state ~= 'playing' then return 'EQ' end
  if cfg.realSpectrum then
    if pcm.status == 'ready' then return 'FFT' end
    if pcm.status == 'decoding' then return 'FFT..' end
  end
  if winampStyle then
    return string.format('%d BPM', math.floor(activeBpm() + 0.5))
  end
  return 'EQ'
end

--------------------------------------------------------------------------------
-- SKIN 1: WINAMP (v3.2)
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
  txt(eqModeText(true), 13, 246, 64, state == 'playing' and PAL.text or PAL.dim)

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
-- SKIN 2: RÁDIO AUTOMOTIVO (v3.2)
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
  txt(eqModeText(false), 11, 398, 68, state == 'playing' and PAL.text or PAL.dim)
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
-- SKIN 3: BZR STUDIO (inspirada no BZR Player & @MAX Tray Player)
--------------------------------------------------------------------------------
local function vsliderBZR(id, x, y, w, h, value, label)
  ui.setCursor(P(x - 6, y - 4))
  local released = ui.invisibleButton(id, vec2((w + 12) * SX, (h + 8) * SY))
  local active = ui.itemActive()
  local hov = ui.itemHovered()
  local frac
  if active or released then
    local my = (ui.mouseLocalPos().y - OY) / math.max(0.001, SY) - y
    frac = clamp01(1 - my / h)
  elseif hov then
    local wh = ui.mouseWheel()
    if wh ~= 0 then frac = clamp01(value + wh * 0.05) end
  end
  local v = frac or value

  if label then ctext(label, 8.5, x + w / 2, y - 8, rgbm(0.76, 0.78, 0.82, 0.88)) end

  for t = 0, 10 do
    local ty = y + (t / 10) * h
    local len = (t % 5 == 0) and 6 or 3.5
    ui.drawLine(P(x - len - 2, ty), P(x - 2, ty), rgbm(0.10, 0.11, 0.13, 0.9), math.max(0.8, SX))
    ui.drawLine(P(x + w + 2, ty), P(x + w + 2 + len, ty), rgbm(0.10, 0.11, 0.13, 0.9), math.max(0.8, SX))
  end

  local cx = x + w / 2
  rect(cx - 2.5, y, cx + 2.5, y + h, rgbm(0.05, 0.06, 0.08, 1), 1)
  border(cx - 2.5, y, cx + 2.5, y + h, rgbm(1, 1, 1, 0.12), 1)

  local cy = y + (1 - v) * h
  local kw, kh = 18, 11
  rect(cx - kw / 2, cy - kh / 2 + 2, cx + kw / 2, cy + kh / 2 + 2, rgbm(0, 0, 0, 0.65), 2)
  ui.drawRectFilledMultiColor(
    P(cx - kw / 2, cy - kh / 2), P(cx + kw / 2, cy + kh / 2),
    rgbm(0.32, 0.34, 0.38, 1), rgbm(0.32, 0.34, 0.38, 1),
    rgbm(0.10, 0.11, 0.14, 1), rgbm(0.10, 0.11, 0.14, 1)
  )
  border(cx - kw / 2, cy - kh / 2, cx + kw / 2, cy + kh / 2, rgbm(0, 0, 0, 0.9), 1)
  ui.drawLine(P(cx - kw / 2 + 2, cy), P(cx + kw / 2 - 2, cy), PAL.on, math.max(1.2, 1.5 * SX))

  return frac, released, active or (hov and frac ~= nil)
end

local function ledRadioBZR(id, x, y, label, lit)
  ui.setCursor(P(x - 4, y - 7))
  local clicked = ui.invisibleButton(id, vec2(96 * SX, 14 * SY))
  local r = 5.5
  ui.drawCircleFilled(P(x + r, y), r * SX, rgbm(0.12, 0.13, 0.16, 1), 16)
  ui.drawCircle(P(x + r, y), r * SX, rgbm(0.03, 0.03, 0.05, 1), 16, math.max(1, 1.3 * SX))
  if lit then
    ui.drawCircleFilled(P(x + r, y), (r + 2.5) * SX, PAL.glow, 16)
    ui.drawCircleFilled(P(x + r, y), (r - 2) * SX, PAL.on, 16)
  else
    ui.drawCircleFilled(P(x + r, y), (r - 2.5) * SX, rgbm(0.24, 0.25, 0.28, 1), 12)
  end
  txt(label, 8.5, x + r * 2 + 5, y - 5, lit and PAL.text or rgbm(0.75, 0.77, 0.82, 0.82))
  return clicked
end

local function seekBarBZR(x, y, w, h)
  local cur, dur = playbackTimes()
  local val = (dur > 0) and clamp01(cur / dur) or 0
  ui.setCursor(P(x, y - 5))
  local released = ui.invisibleButton('seek_bzr', vec2(w * SX, (h + 10) * SY))
  local active = ui.itemActive()
  local frac
  if active or released then
    local mx = (ui.mouseLocalPos().x - OX) / math.max(0.001, SX) - x
    frac = clamp01(mx / w)
  end
  local v = frac or val
  local cy = y + h / 2

  for i = 0, 44 do
    local tx = x + (i / 44) * w
    local th = (i % 4 == 0) and 5 or 2.5
    ui.drawLine(P(tx, cy - th - 2), P(tx, cy + th + 2), rgbm(0.14, 0.15, 0.18, 0.9), math.max(0.8, SX))
  end

  rect(x, cy - 2, x + w, cy + 2, rgbm(0.04, 0.04, 0.06, 1), 1)
  ui.drawLine(P(x, cy), P(x + w * v, cy), PAL.on, math.max(1.2, 1.8 * SX))

  local kx = x + w * v
  rect(kx - 6, y - 2, kx + 6, y + h + 2, rgbm(0.12, 0.13, 0.16, 1), 2)
  border(kx - 6, y - 2, kx + 6, y + h + 2, rgbm(0, 0, 0, 0.95), 1.2)
  ui.drawLine(P(kx, y), P(kx, y + h), PAL.on, math.max(1.2, 2 * SX))

  if released and frac and player and dur > 0 and state ~= 'stopped' then
    pcall(function() player:setCurrentTime(frac * dur) end)
  end
end

local function roundBtnBZR(id, cx, cy, r, icon, lit)
  ui.setCursor(P(cx - r, cy - r))
  local clicked = ui.invisibleButton(id, vec2(r * 2 * SX, r * 2 * SY))
  local hov, act = ui.itemHovered(), ui.itemActive()

  ui.drawCircleFilled(P(cx, cy), (r + 2.5) * SX, rgbm(0.05, 0.05, 0.07, 0.95), 32)
  if lit or hov then
    ui.drawCircleFilled(P(cx, cy), (r + 4.5) * SX, PAL.glow, 32)
    ui.drawCircle(P(cx, cy), (r + 1.2) * SX, lit and PAL.on or PAL.border, 32, math.max(1.2, 2 * SX))
  else
    ui.drawCircle(P(cx, cy), (r + 1) * SX, rgbm(0.28, 0.30, 0.34, 0.8), 32, math.max(1, 1.2 * SX))
  end

  local baseCol = act and rgbm(0.12, 0.13, 0.16, 1) or (hov and rgbm(0.25, 0.27, 0.31, 1) or rgbm(0.19, 0.20, 0.24, 1))
  ui.drawCircleFilled(P(cx, cy), (r - 1) * SX, baseCol, 32)
  ui.drawCircleFilled(P(cx - r * 0.22, cy - r * 0.25), r * 0.42 * SX, rgbm(1, 1, 1, 0.06), 20)

  icon(cx, cy, lit and PAL.on or rgbm(0.84, 0.86, 0.90, 1))
  return clicked
end

local function drawBZR()
  local tr, cat = currentTrack(), library[cfg.folder]
  local cur, dur = playbackTimes()
  local shown = cfg.showRemaining and math.max(0, dur - cur) or cur

  fillBody(rgbm(0.36, 0.37, 0.40, 1), rgbm(0.18, 0.19, 0.21, 1), 0.18)
  for yy = 4, 186, 3 do
    ui.drawLine(P(0, yy), P(DW, yy), rgbm(1, 1, 1, (yy % 6 == 0) and 0.025 or 0.01), math.max(0.8, SX))
  end

  ui.drawRectFilledMultiColor(
    P(0, 0), P(DW, 17),
    rgbm(0.46, 0.47, 0.50, 1), rgbm(0.46, 0.47, 0.50, 1),
    rgbm(0.24, 0.25, 0.28, 1), rgbm(0.24, 0.25, 0.28, 1)
  )
  ui.drawLine(P(0, 17), P(DW, 17), rgbm(0.06, 0.06, 0.08, 0.9), math.max(1, SX))
  txt('@MAX / BZR STUDIO', 9.5, 12, 2, rgbm(0.86, 0.88, 0.92, 0.85))
  ctext('B Z R   P L A Y E R', 10.5, 280, 8.5, rgbm(0.14, 0.15, 0.17, 0.95))

  rect(12, 20, 350, 116, rgbm(0.08, 0.09, 0.11, 1), 3)
  ui.drawRectFilledMultiColor(P(14, 22), P(348, 114), PAL.lcdTop, PAL.lcdTop, PAL.lcdBot, PAL.lcdBot)
  border(14, 22, 348, 114, rgbm(0.04, 0.05, 0.06, 0.95), 2)

  rect(20, 27, 138, 86, rgbm(0.05, 0.06, 0.08, 0.92), 2)
  border(20, 27, 138, 86, PAL.border, 1)
  txt('dB', 8, 23, 30, PAL.dim)
  if state == 'playing' then
    ui.drawTriangleFilled(P(38, 31), P(38, 39), P(45, 35), PAL.on)
  else
    rect(38, 31, 44, 38, PAL.dim)
  end
  txt(eqModeText(false), 8.5, 50, 30, PAL.text)
  txt('20HZ', 7.5, 23, 75, PAL.dim)
  txt('20KHZ', 7.5, 106, 75, PAL.dim)

  local gMini = grad(10)
  local mbw = 108 / BARS
  for i = 1, BARS do
    local bx = 25 + (i - 1) * mbw
    local bh = lvl[i] * 30
    local colIdx = clamp(math.ceil(lvl[i] * 10), 1, 10)
    if bh > 1 then
      rect(bx, 72 - bh, bx + mbw - 1, 72, gMini[colIdx])
    end
    local pky = 72 - peak[i] * 30
    rect(bx, pky - 1.5, bx + mbw - 1, pky, PAL.peak)
  end

  drawSeg7Custom('88:88', 214, 27, 21, 36, 4.5, 5, PAL.lcdGhost, PAL.lcdGhost, nil)
  if cfg.showRemaining then
    rect(200, 43, 209, 47, PAL.lcdInk, 1)
  end
  drawSeg7Custom(fmtTime(shown), 214, 27, 21, 36, 4.5, 5, PAL.lcdInk, PAL.lcdGhost, nil)
  ui.setCursor(P(198, 25))
  if ui.invisibleButton('bzr_time', vec2(146 * SX, 40 * SY)) then
    cfg.showRemaining = not cfg.showRemaining
  end

  local waveY = 68
  local prevX, prevY = 142, waveY
  local segsW = 36
  for s = 1, segsW do
    local fx = s / segsW
    local wx = 142 + fx * 202
    local bIdx = clamp(math.floor(fx * BARS) + 1, 1, BARS)
    local amp = (state == 'playing') and (lvl[bIdx] * 11 * math.sin(clock * 26 + s * 1.35)) or 0
    local wy = clamp(waveY + amp, 54, 82)
    ui.drawLine(P(prevX, prevY), P(wx, wy), PAL.lcdInk, math.max(1, 1.3 * SX))
    prevX, prevY = wx, wy
  end

  txt('ST: ' .. (cat and cat.name:sub(1, 12) or 'NENHUMA'), 9, 144, 28, PAL.lcdMid)
  txt('KHZ: 44.1  ' .. (tr and tr.ext or 'MP3'), 9, 144, 41, PAL.lcdMid)
  txt(string.format('TRK: %02d/%02d  [%s]', current, cat and #cat.tracks or 0, eqModeText(true)), 9, 144, 78, PAL.lcdInk)

  rect(18, 93, 344, 111, rgbm(0, 0, 0, 0.14), 1)
  drawMarquee(marqueeText() .. ' (' .. fmtTime(dur) .. ')', 11.5, 22, 95, 340, 110, PAL.lcdInk)

  local intF, _, intAct = vsliderBZR('bzr_int', 368, 34, 16, 72, clamp01((cfg.intensity - 0.3) / 1.2), 'INTENS')
  if intF and intAct then cfg.intensity = 0.3 + intF * 1.2 end

  local volF, _, volAct = vsliderBZR('bzr_vol', 410, 34, 16, 72, cfg.volume, 'VOLUME')
  if volF and volAct then setVolume(volF) end

  if ledRadioBZR('bzr_fft', 446, 36, 'FFT REAL', cfg.realSpectrum) then
    cfg.realSpectrum = not cfg.realSpectrum
    if tr then startAnalysis(tr) end
  end
  if ledRadioBZR('bzr_rem', 446, 55, 'REMAIN', cfg.showRemaining) then
    cfg.showRemaining = not cfg.showRemaining
  end
  if ledRadioBZR('bzr_shf', 446, 74, 'SHUFFLE', cfg.shuffle) then
    cfg.shuffle = not cfg.shuffle
  end
  if ledRadioBZR('bzr_rep', 446, 93, 'REPEAT', cfg.repeatAll) then
    cfg.repeatAll = not cfg.repeatAll
  end

  seekBarBZR(16, 122, 332, 12)

  rect(364, 117, 546, 139, rgbm(0.09, 0.10, 0.12, 1), 3)
  border(364, 117, 546, 139, PAL.border, 1, 3)
  if btn('bzr_dp', 366, 119, 22, 18, iconDirPrev) then stepFolder(-1) end
  drawMarquee('ESTACAO: ' .. (cat and cat.name or 'SEM PASTA'), 10, 392, 121, 518, 136, PAL.text)
  if btn('bzr_dn', 522, 119, 22, 18, iconDirNext) then stepFolder(1) end

  local by = 163
  if roundBtnBZR('bzr_prev', 36, by, 17, iconPrev, false) then prevTrack() end
  if roundBtnBZR('bzr_play', 78, by, 19, iconPlay, state == 'playing') then doPlay() end
  if roundBtnBZR('bzr_pause', 120, by, 17, iconPause, state == 'paused') then doPause() end
  if roundBtnBZR('bzr_stop', 160, by, 17, iconStop, state == 'stopped') then stopPlayback() end
  if roundBtnBZR('bzr_next', 200, by, 17, iconNext, false) then nextTrack(false) end

  if roundBtnBZR('bzr_fprev', 242, by, 12, iconDirPrev, false) then stepFolder(-1) end
  if roundBtnBZR('bzr_fnext', 270, by, 12, iconDirNext, false) then stepFolder(1) end

  if roundBtnBZR('bzr_eqm', 428, by, 12, iconText('FFT', 8.5), cfg.realSpectrum) then
    cfg.realSpectrum = not cfg.realSpectrum
    if tr then startAnalysis(tr) end
  end
  if roundBtnBZR('bzr_shb', 458, by, 12, iconText('SHF', 8.5), cfg.shuffle) then
    cfg.shuffle = not cfg.shuffle
  end
  if roundBtnBZR('bzr_rpb', 488, by, 12, iconText('REP', 8.5), cfg.repeatAll) then
    cfg.repeatAll = not cfg.repeatAll
  end
  if roundBtnBZR('bzr_skn', 522, by, 12, iconText('SKN', 8.5), true) then
    cfg.skin = (cfg.skin % 5) + 1
  end
end

--------------------------------------------------------------------------------
-- SKIN 4: AIMP DECK (inspirada no AIMP Classic & JetAudio)
--------------------------------------------------------------------------------
local EQ_PRESETS = { 'ROCK', 'POP', 'JAZZ', 'CLASSIC', 'FLAT' }

local function sliderAimp(id, x, y, w, h, value, label)
  ui.setCursor(P(x - 4, y - 6))
  local released = ui.invisibleButton(id, vec2((w + 8) * SX, (h + 12) * SY))
  local active = ui.itemActive()
  local hov = ui.itemHovered()
  local frac
  if active or released then
    local mx = (ui.mouseLocalPos().x - OX) / math.max(0.001, SX) - x
    frac = clamp01(mx / w)
  elseif hov then
    local wh = ui.mouseWheel()
    if wh ~= 0 then frac = clamp01(value + wh * 0.05) end
  end
  local v = frac or value

  if label then txt(label, 8, x, y - 10, rgbm(0.22, 0.24, 0.28, 0.95)) end

  rect(x, y, x + w, y + h, rgbm(0.20, 0.21, 0.24, 1), 2)
  if v > 0.005 then
    ui.drawRectFilledMultiColor(P(x, y), P(x + w * v, y + h), PAL.seekA, PAL.on, PAL.on, PAL.seekA)
  end
  border(x, y, x + w, y + h, rgbm(0.10, 0.11, 0.13, 0.9), 1, 2)

  local kx = x + w * v
  rect(kx - 7, y - 3.5, kx + 7, y + h + 3.5, rgbm(0.95, 0.96, 0.98, 1), 2)
  border(kx - 7, y - 3.5, kx + 7, y + h + 3.5, rgbm(0.18, 0.20, 0.24, 1), 1, 2)
  ui.drawLine(P(kx, y - 1.5), P(kx, y + h + 1.5), PAL.on, math.max(1, 1.4 * SX))

  return frac, released, active or (hov and frac ~= nil)
end

local function roundBtnAimp(id, cx, cy, r, icon, lit, metallic)
  ui.setCursor(P(cx - r, cy - r))
  local clicked = ui.invisibleButton(id, vec2(r * 2 * SX, r * 2 * SY))
  local hov, act = ui.itemHovered(), ui.itemActive()

  ui.drawCircleFilled(P(cx, cy + 1.5), (r + 1) * SX, rgbm(0, 0, 0, 0.35), 32)

  if metallic then
    local c1 = act and rgbm(0.55, 0.57, 0.60, 1) or (hov and rgbm(0.82, 0.84, 0.88, 1) or rgbm(0.72, 0.74, 0.78, 1))
    ui.drawCircleFilled(P(cx, cy), r * SX, c1, 32)
    ui.drawCircle(P(cx, cy), r * SX, rgbm(0.20, 0.22, 0.25, 1), 32, math.max(1, 1.3 * SX))
    icon(cx, cy, rgbm(0.12, 0.13, 0.16, 1))
  else
    local cFill = act and PAL.aimpBtnLo or (hov and PAL.on or PAL.aimpBtnHi)
    if lit then
      ui.drawCircleFilled(P(cx, cy), (r + 3.5) * SX, PAL.glow, 32)
    end
    ui.drawCircleFilled(P(cx, cy), r * SX, cFill, 32)
    ui.drawCircleFilled(P(cx - r * 0.22, cy - r * 0.25), r * 0.45 * SX, rgbm(1, 1, 1, 0.22), 20)
    ui.drawCircle(P(cx, cy), r * SX, rgbm(0.10, 0.11, 0.14, 0.95), 32, math.max(1, 1.5 * SX))
    icon(cx, cy, rgbm(0.06, 0.06, 0.08, 1))
  end

  return clicked
end

local function drawAimp()
  local tr, cat = currentTrack(), library[cfg.folder]
  local cur, dur = playbackTimes()
  local shown = cfg.showRemaining and math.max(0, dur - cur) or cur

  fillBody(rgbm(0.86, 0.87, 0.90, 1), rgbm(0.68, 0.70, 0.74, 1), 0.45)

  ui.drawRectFilledMultiColor(
    P(0, 0), P(DW, 17),
    rgbm(0.32, 0.34, 0.38, 1), rgbm(0.32, 0.34, 0.38, 1),
    rgbm(0.18, 0.19, 0.22, 1), rgbm(0.18, 0.19, 0.22, 1)
  )
  txt('RETRO DECK // JET-DSP', 9, 10, 2.5, rgbm(0.85, 0.87, 0.92, 0.85))
  ctext('A I M P   D E C K', 10.5, 280, 8.5, PAL.on)
  rect(538, 3, 552, 14, PAL.aimpBtnHi, 2)
  border(538, 3, 552, 14, rgbm(0.08, 0.08, 0.10, 1), 1, 2)

  rect(12, 21, 548, 122, rgbm(0.06, 0.07, 0.09, 1), 6)
  border(12, 21, 548, 122, rgbm(0.25, 0.26, 0.30, 1), 2, 6)

  rect(16, 24, 544, 43, rgbm(0.11, 0.12, 0.15, 1), 3)
  ui.drawLine(P(16, 43), P(544, 43), rgbm(1, 1, 1, 0.08), math.max(1, SX))
  local aimpTitle = tr
    and string.format('%02d :: %s :: %s :: 44 kHz, 320 kbps', current, tr.title, tr.ext)
    or '00 :: APERTE PLAY PARA INICIAR :: MP3 :: 44 kHz, 320 kbps'
  drawMarquee(aimpTitle, 11.5, 20, 26, 540, 41, rgbm(0.95, 0.96, 0.98, 1))

  rect(16, 46, 116, 118, rgbm(0.10, 0.11, 0.13, 1), 2)
  txt('320 KBPS', 8.5, 22, 50, PAL.text)
  txt('44.1 KHZ', 8.5, 22, 62, PAL.dim)
  txt('MODE: ' .. eqModeText(false), 8.5, 22, 74, PAL.on)
  txt('> ' .. (cat and cat.name:sub(1, 10) or 'RAIZ'), 8.5, 22, 86, rgbm(0.80, 0.82, 0.86, 0.9))

  if btn('aimp_shf', 20, 100, 44, 15, iconText('SHUF', 8.5), cfg.shuffle) then cfg.shuffle = not cfg.shuffle end
  if btn('aimp_rep', 68, 100, 44, 15, iconText('REP', 8.5), cfg.repeatAll) then cfg.repeatAll = not cfg.repeatAll end

  ui.drawRectFilledMultiColor(P(120, 46), P(404, 118), PAL.dispTop, PAL.dispTop, rgbm(0.01, 0.01, 0.02, 1), rgbm(0.01, 0.01, 0.02, 1))
  border(120, 46, 404, 118, rgbm(0, 0, 0, 0.95), 1.5)

  local vcx, vcy = 262, 76
  local bassPulse = (lvl[1] + lvl[2] + lvl[3]) / 3
  for r = 1, 3 do
    local radX = (22 + r * 26 + ((clock * 25) % 26)) * (0.9 + 0.15 * bassPulse)
    local radY = radX * 0.36
    border(vcx - radX, vcy - radY, vcx + radX, vcy + radY, palA(0.14), 1, 2)
  end

  local gVis = grad(12)
  local halfW = 132 / BARS
  for i = 1, BARS do
    local hBar = lvl[i] * 44
    local cIdx = clamp(math.ceil(lvl[i] * 12), 1, 12)
    local dx = (i - 1) * halfW
    if hBar > 1 then
      rect(vcx - dx - halfW + 0.5, 99 - hBar, vcx - dx - 0.5, 99, gVis[cIdx])
      rect(vcx + dx + 0.5, 99 - hBar, vcx + dx + halfW - 0.5, 99, gVis[cIdx])
    end
  end

  rect(122, 102, 402, 116, rgbm(0.04, 0.05, 0.08, 0.9), 1)
  local pw = 276 / #EQ_PRESETS
  for i, name in ipairs(EQ_PRESETS) do
    local px = 124 + (i - 1) * pw
    local activeP = (cfg.eqPreset == i)
    if activeP then
      rect(px, 103, px + pw - 2, 115, PAL.on, 2)
    end
    ctext(name, 8, px + pw / 2 - 1, 109, activeP and rgbm(0.05, 0.05, 0.08, 1) or PAL.dim)
    ui.setCursor(P(px, 102))
    if ui.invisibleButton('aimp_eq_' .. i, vec2(pw * SX, 14 * SY)) then
      cfg.eqPreset = i
    end
  end

  rect(408, 46, 544, 118, rgbm(0.08, 0.09, 0.11, 1), 2)
  ui.drawCircle(P(424, 62), 9 * SX, PAL.dim, 20, math.max(1, 1.5 * SX))
  ui.drawLine(P(424, 62), P(424, 56), PAL.on, math.max(1, 1.4 * SX))
  ui.drawLine(P(424, 62), P(429, 62), PAL.on, math.max(1, 1.4 * SX))

  drawSeg7Custom('88:88', 442, 50, 15, 25, 3.5, 4, PAL.segOff, PAL.segOff, nil)
  drawSeg7Custom(fmtTime(shown), 442, 50, 15, 25, 3.5, 4, rgbm(0.95, 0.96, 0.98, 1), PAL.segOff, PAL.glow)
  txt(fmtTimeLong(dur), 9.5, 442, 77, PAL.on)
  ui.setCursor(P(412, 48))
  if ui.invisibleButton('aimp_time', vec2(128 * SX, 38 * SY)) then
    cfg.showRemaining = not cfg.showRemaining
  end

  drawSpectrum(414, 91, 124, 24, 7, 1.5)

  local seekFrac = (dur > 0) and clamp01(cur / dur) or 0
  local sf, sRel = sliderAimp('aimp_seek', 16, 129, 528, 6, seekFrac)
  if sRel and sf and player and dur > 0 and state ~= 'stopped' then
    pcall(function() player:setCurrentTime(sf * dur) end)
  end

  ui.drawLine(P(12, 143), P(548, 143), rgbm(1, 1, 1, 0.55), math.max(1, SX))

  local by = 164
  if roundBtnAimp('aimp_play', 34, by, 18, iconPlay, state == 'playing', false) then doPlay() end
  if roundBtnAimp('aimp_pause', 72, by, 14.5, iconPause, state == 'paused', false) then doPause() end
  if roundBtnAimp('aimp_stop', 105, by, 14.5, iconStop, state == 'stopped', false) then stopPlayback() end
  if roundBtnAimp('aimp_prev', 138, by, 14.5, iconPrev, false, false) then prevTrack() end
  if roundBtnAimp('aimp_next', 171, by, 14.5, iconNext, false, false) then nextTrack(false) end
  if roundBtnAimp('aimp_ej', 202, by, 11.5, iconEject, false, true) then stepFolder(1) end

  local vf, _, vAct = sliderAimp('aimp_vol', 236, 154, 118, 5, cfg.volume, string.format('VOLUME: %d%%', math.floor(cfg.volume * 100 + 0.5)))
  if vf and vAct then setVolume(vf) end

  local intNorm = clamp01((cfg.intensity - 0.3) / 1.2)
  local inf, _, inAct = sliderAimp('aimp_int', 236, 175, 118, 5, intNorm, string.format('PULSE GAIN: %d%%', math.floor(cfg.intensity * 100 + 0.5)))
  if inf and inAct then cfg.intensity = 0.3 + inf * 1.2 end

  if roundBtnAimp('aimp_st', 384, by, 15, iconText('DIR', 9), false, false) then stepFolder(1) end

  rect(408, 148, 546, 180, rgbm(0.14, 0.15, 0.18, 1), 3)
  border(408, 148, 546, 180, rgbm(0.05, 0.05, 0.07, 1), 1.2, 3)
  if btn('aimp_dp', 411, 151, 24, 26, iconDirPrev) then stepFolder(-1) end
  ctext(cat and cat.name:sub(1, 10) or 'ESTACAO', 9.5, 477, 158, PAL.on)
  ctext(string.format('FAIXA %02d/%02d', current, cat and #cat.tracks or 0), 8.5, 477, 170, PAL.text)
  if btn('aimp_dn', 519, 151, 24, 26, iconDirNext) then stepFolder(1) end
end

--------------------------------------------------------------------------------
-- SKIN 5: MIDNIGHT X-AMP (1X-AMP-PROFESSIONAL + SONIQUE + LOGO MIDNIGHT SUMMIT)
-- A logo MIDNIGHT SUMMIT aparece EXCLUSIVAMENTE nesta skin.
--------------------------------------------------------------------------------
local FX_LABELS = { 'EQ', 'DELAY', 'REVERB', 'P. SCALE', 'P. SHIFT', 'TEMPO', '3D', 'TREBLE', 'BASS' }
local fxState = { true, false, false, false, false, false, true, false, true }
local xampKnobDrag = 0

-- Desenha o brasão completo da equipe MIDNIGHT SUMMIT (vetorial + suporte a PNG)
local function drawMidnightSummitCrest(cx, cy, sc, alpha, pulse)
  alpha = alpha or 1
  pulse = pulse or 0

  -- Se o usuário colocar midnight_summit.png na pasta do app, renderiza a imagem
  if hasLogoPng and ui. drawImage then
    local wImg, hImg = 156 * sc, 92 * sc
    pcall(function()
      ui.drawImage(LOGO_PNG, P(cx - wImg * 0.5, cy - hImg * 0.5), P(cx + wImg * 0.5, cy + hImg * 0.5), rgbm(1, 1, 1, alpha))
    end)
    return
  end

  local cSilver = rgbm(0.84, 0.86, 0.90, alpha)
  local cChrome = rgbm(0.95, 0.96, 0.99, alpha)
  local cDark   = rgbm(0.06, 0.07, 0.09, alpha * 0.96)
  local cCarbon = rgbm(0.14, 0.15, 0.19, alpha * 0.92)
  local cAccent = hsv(PAL.h, PAL.s, PAL.v, alpha * (0.45 + 0.45 * pulse))

  -- Halo sutil reagindo ao grave da música
  if pulse > 0.02 then
    ui.drawCircleFilled(P(cx, cy), 46 * sc * SX, hsv(PAL.h, PAL.s, PAL.v, alpha * 0.16 * pulse), 32)
  end

  -- 3 Asas metálicas horizontais de cada lado (estilo emblema Midnight Summit)
  for w = 0, 2 do
    local wy = cy - (10 - w * 7) * sc
    local wLen = (74 - w * 7) * sc
    local wIn  = 34 * sc
    -- Esquerda
    ui.drawTriangleFilled(P(cx - wLen, wy - 2 * sc), P(cx - wIn, wy - 2 * sc), P(cx - wIn, wy + 2.5 * sc), cSilver)
    ui.drawLine(P(cx - wLen, wy - 2 * sc), P(cx - wIn, wy - 2 * sc), cChrome, math.max(1, 1.2 * SX))
    -- Direita
    ui.drawTriangleFilled(P(cx + wLen, wy - 2 * sc), P(cx + wIn, wy - 2 * sc), P(cx + wIn, wy + 2.5 * sc), cSilver)
    ui.drawLine(P(cx + wLen, wy - 2 * sc), P(cx + wIn, wy - 2 * sc), cChrome, math.max(1, 1.2 * SX))
  end

  -- Engrenagens e pistões laterais inferiores
  local gxL, gxR, gyG = cx - 37 * sc, cx + 37 * sc, cy + 12 * sc
  ui.drawCircleFilled(P(gxL, gyG), 11 * sc * SX, cSilver, 16)
  ui.drawCircleFilled(P(gxL, gyG), 6 * sc * SX, cDark, 16)
  ui.drawCircleFilled(P(gxR, gyG), 11 * sc * SX, cSilver, 16)
  ui.drawCircleFilled(P(gxR, gyG), 6 * sc * SX, cDark, 16)

  -- Escudo central (borda cromada + interior fibra de carbono)
  local shW, shTop, shMid, shBot = 40 * sc, cy - 26 * sc, cy + 18 * sc, cy + 44 * sc
  rect(cx - shW - 2.5 * sc, shTop - 2 * sc, cx + shW + 2.5 * sc, shMid, cSilver, 3)
  ui.drawTriangleFilled(P(cx - shW - 2.5 * sc, shMid), P(cx + shW + 2.5 * sc, shMid), P(cx, shBot + 3 * sc), cSilver)

  rect(cx - shW, shTop, cx + shW, shMid, cDark, 2)
  ui.drawTriangleFilled(P(cx - shW, shMid), P(cx + shW, shMid), P(cx, shBot), cDark)

  -- Contorno neon sutil no escudo
  ui.drawLine(P(cx - shW, shTop), P(cx - shW, shMid), cAccent, math.max(1, 1.2 * SX))
  ui.drawLine(P(cx + shW, shTop), P(cx + shW, shMid), cAccent, math.max(1, 1.2 * SX))
  ui.drawLine(P(cx - shW, shMid), P(cx, shBot), cAccent, math.max(1, 1.2 * SX))
  ui.drawLine(P(cx + shW, shMid), P(cx, shBot), cAccent, math.max(1, 1.2 * SX))

  -- Picos das montanhas gêmeas no topo do escudo
  ui.drawTriangleFilled(P(cx - 24 * sc, cy - 11 * sc), P(cx - 7 * sc, cy - 25 * sc), P(cx + 4 * sc, cy - 11 * sc), cChrome)
  ui.drawTriangleFilled(P(cx - 5 * sc, cy - 11 * sc), P(cx + 9 * sc, cy - 28 * sc), P(cx + 26 * sc, cy - 11 * sc), cChrome)
  ui.drawTriangleFilled(P(cx - 2 * sc, cy - 11 * sc), P(cx + 9 * sc, cy - 24 * sc), P(cx + 15 * sc, cy - 11 * sc), cCarbon)

  -- Placa superior com Katakana: ミッドナイトサミット
  rect(cx - 50 * sc, cy - 41 * sc, cx + 50 * sc, cy - 27 * sc, cDark, 3)
  border(cx - 50 * sc, cy - 41 * sc, cx + 50 * sc, cy - 27 * sc, cSilver, 1.2, 3)
  ctext('ミッドナイトサミット', 8.5 * sc, cx, cy - 34 * sc, cChrome)

  -- Tipografia principal: MIDNIGHT SUMMIT
  ctext('MIDNIGHT', 12 * sc, cx, cy - 4 * sc, cChrome)
  ctext('SUMMIT', 12.5 * sc, cx, cy + 7.5 * sc, cSilver)

  -- Faixa preta inferior: 峠の支配者 / MASTERS OF THE PASS
  rect(cx - 43 * sc, cy + 14 * sc, cx + 43 * sc, cy + 27 * sc, rgbm(0.03, 0.03, 0.05, alpha), 2)
  border(cx - 43 * sc, cy + 14 * sc, cx + 43 * sc, cy + 27 * sc, cSilver, 1, 2)
  ctext('峠の支配者', 7.5 * sc, cx, cy + 18 * sc, cChrome)
  ctext('MASTERS OF THE PASS', 5.8 * sc, cx, cy + 24 * sc, cSilver)

  -- Bandeira quadriculada à esquerda + Estrada de Touge em "S" na ponta inferior
  for r = 0, 1 do
    for c = 0, 2 do
      if (r + c) % 2 == 0 then
        local qx = cx - 22 * sc + c * 4.2 * sc
        local qy = cy + 28.5 * sc + r * 4.0 * sc
        rect(qx, qy, qx + 4 * sc, qy + 3.8 * sc, cSilver)
      end
    end
  end

  -- Curva de Touge estilizada no vértice do escudo
  ui.drawLine(P(cx + 6 * sc, cy + 28 * sc), P(cx - 6 * sc, cy + 34 * sc), cChrome, math.max(1.2, 2.0 * sc * SX))
  ui.drawLine(P(cx - 6 * sc, cy + 34 * sc), P(cx + 8 * sc, cy + 39 * sc), cChrome, math.max(1.2, 2.2 * sc * SX))
  ui.drawLine(P(cx + 8 * sc, cy + 39 * sc), P(cx, cy + 43 * sc), cAccent, math.max(1.2, 2.2 * sc * SX))
end

local function fxBtnXamp(id, x, y, w, h, label, lit)
  ui.setCursor(P(x, y))
  local clicked = ui.invisibleButton(id, vec2(w * SX, h * SY))
  local hov, act = ui.itemHovered(), ui.itemActive()

  rect(x - 1, y - 1, x + w + 1, y + h + 1, rgbm(0.04, 0.04, 0.05, 0.95), 2)
  local top = act and rgbm(0.14, 0.14, 0.16, 1) or (hov and rgbm(0.32, 0.31, 0.34, 1) or rgbm(0.24, 0.23, 0.25, 1))
  local bot = act and rgbm(0.08, 0.08, 0.10, 1) or rgbm(0.11, 0.11, 0.13, 1)
  ui.drawRectFilledMultiColor(P(x, y), P(x + w, y + h), top, top, bot, bot)
  ui.drawLine(P(x + 1, y + 1), P(x + w - 1, y + 1), rgbm(1, 1, 1, 0.18), math.max(0.8, SX))

  ctext(label, 7.8, x + w / 2, y + h * 0.38, rgbm(0.86, 0.85, 0.88, 1))

  -- Mini LED quadrado na base do botão (estilo 1X-AMP-PROFESSIONAL)
  local lx, ly = x + w / 2 - 2.5, y + h - 5.5
  if lit then
    rect(lx - 1.5, ly - 1.5, lx + 6.5, ly + 4.5, PAL.glow, 1)
    rect(lx, ly, lx + 5, ly + 3, PAL.on, 0.5)
  else
    rect(lx, ly, lx + 5, ly + 3, rgbm(0.06, 0.06, 0.08, 1), 0.5)
  end

  return clicked
end

local function toggleSwitchXamp(id, cx, cy, label, onState)
  ctext(label, 7.5, cx, cy - 13, rgbm(0.92, 0.92, 0.95, 0.9))
  ui.setCursor(P(cx - 9, cy - 8))
  local clicked = ui.invisibleButton(id, vec2(18 * SX, 24 * SY))

  -- Cavidade metálica vertical
  rect(cx - 4.5, cy - 6, cx + 4.5, cy + 14, rgbm(0.08, 0.08, 0.10, 1), 4)
  border(cx - 4.5, cy - 6, cx + 4.5, cy + 14, rgbm(0.55, 0.54, 0.58, 0.8), 1, 4)

  -- Pino cromado da chave seletora
  local py = onState and (cy - 1) or (cy + 8)
  ui.drawCircleFilled(P(cx, py + 1), 5 * SX, rgbm(0, 0, 0, 0.65), 16)
  ui.drawCircleFilled(P(cx, py), 4.5 * SX, onState and PAL.on or rgbm(0.78, 0.78, 0.82, 1), 16)
  ui.drawCircleFilled(P(cx - 1.2, py - 1.2), 1.8 * SX, rgbm(1, 1, 1, 0.75), 10)

  return clicked
end

local function drawXampKnob(cx, cy, r)
  -- Pontos de escala ao redor do grande dial (estilo 1X-AMP)
  local dots = 15
  for i = 0, dots - 1 do
    local f = i / (dots - 1)
    local a = math.rad(135 + 270 * f)
    local dx = cx + math.cos(a) * (r + 8)
    local dy = cy + math.sin(a) * (r + 8)
    local isMajor = (i % 3 == 0)
    local lit = (f <= cfg.volume + 0.005)
    local col = lit and PAL.on or rgbm(0.10, 0.10, 0.12, 0.95)
    if isMajor then
      rect(dx - 2, dy - 2, dx + 2, dy + 2, col, 0.5)
    else
      ui.drawCircleFilled(P(dx, dy), 1.3 * SX, col, 8)
    end
  end

  -- Sombra externa e chanfro do dial de alumínio torneado
  ui.drawCircleFilled(P(cx + 2, cy + 3), (r + 2) * SX, rgbm(0, 0, 0, 0.55), 48)
  ui.drawCircleFilled(P(cx, cy), (r + 1) * SX, rgbm(0.24, 0.24, 0.26, 1), 48)
  ui.drawCircleFilled(P(cx, cy), (r - 2) * SX, rgbm(0.46, 0.45, 0.48, 1), 48)

  -- Anéis concêntricos de metal escovado + reflexo cônico
  for k = 1, 9 do
    local rk = r * (0.18 + k * 0.08)
    local shade = (k % 2 == 0) and 0.54 or 0.38
    ui.drawCircle(P(cx, cy), rk * SX, rgbm(shade, shade - 0.01, shade + 0.01, 0.55), 40, math.max(0.8, 1.2 * SX))
  end
  ui.drawCircleFilled(P(cx - r * 0.28, cy - r * 0.28), r * 0.38 * SX, rgbm(1, 1, 1, 0.10), 24)
  ui.drawCircle(P(cx, cy), (r - 2) * SX, rgbm(0.75, 0.74, 0.78, 0.65), 48, math.max(1, 1.4 * SX))

  -- Fenda indicadora iluminada
  local ang = math.rad(135 + 270 * cfg.volume)
  local x1 = cx + math.cos(ang) * (r * 0.42)
  local y1 = cy + math.sin(ang) * (r * 0.42)
  local x2 = cx + math.cos(ang) * (r * 0.82)
  local y2 = cy + math.sin(ang) * (r * 0.82)
  ui.drawLine(P(x1, y1), P(x2, y2), rgbm(0.92, 0.94, 0.98, 0.95), math.max(1.5, 2.6 * SX))
  ui.drawCircleFilled(P(x2, y2), 2.2 * SX, PAL.on, 12)

  -- Interação: arrastar/scroll = volume | clique = play/pause
  ui.setCursor(P(cx - r, cy - r))
  local clicked = ui.invisibleButton('xamp_knob', vec2(r * 2 * SX, r * 2 * SY))
  local act, hov = ui.itemActive(), ui.itemHovered()
  if hov then
    local wh = ui.mouseWheel()
    if wh ~= 0 then setVolume(cfg.volume + wh * 0.05) end
  end
  if act then
    local d = ui.mouseDelta()
    xampKnobDrag = xampKnobDrag + math.abs(d.x) + math.abs(d.y)
    setVolume(cfg.volume + (d.x - d.y) * 0.005 / math.max(0.2, SX))
  end
  if clicked then
    if xampKnobDrag < 4 * SX then togglePlay() end
    xampKnobDrag = 0
  elseif not act then
    xampKnobDrag = 0
  end
end

local function seekBarXamp(x, y, w, h)
  local cur, dur = playbackTimes()
  local val = (dur > 0) and clamp01(cur / dur) or 0
  ui.setCursor(P(x, y - 5))
  local released = ui.invisibleButton('xamp_seek', vec2(w * SX, (h + 10) * SY))
  local active = ui.itemActive()
  local frac
  if active or released then
    local mx = (ui.mouseLocalPos().x - OX) / math.max(0.001, SX) - x
    frac = clamp01(mx / w)
  end
  local v = frac or val
  local cy = y + h / 2

  -- Fenda horizontal escura (estilo 1X-AMP)
  rect(x, cy - 1.5, x + w, cy + 1.5, rgbm(0.06, 0.06, 0.08, 1), 1)
  ui.drawLine(P(x, cy + 2), P(x + w, cy + 2), rgbm(1, 1, 1, 0.35), math.max(0.8, SX))
  if v > 0.005 then
    ui.drawLine(P(x, cy), P(x + w * v, cy), PAL.on, math.max(1.2, 2.0 * SX))
  end

  -- Bloco metálico ranhurado (|||)
  local kx = x + w * v
  rect(kx - 7, cy - 4.5, kx + 7, cy + 4.5, rgbm(0.78, 0.77, 0.80, 1), 1)
  border(kx - 7, cy - 4.5, kx + 7, cy + 4.5, rgbm(0.12, 0.12, 0.15, 0.95), 1, 1)
  for g = -3, 3, 3 do
    ui.drawLine(P(kx + g, cy - 3), P(kx + g, cy + 3), rgbm(0.20, 0.20, 0.24, 0.9), math.max(0.8, SX))
  end

  if released and frac and player and dur > 0 and state ~= 'stopped' then
    pcall(function() player:setCurrentTime(frac * dur) end)
  end
end

local function transportBtnXamp(id, x, y, w, h, icon, lit)
  ui.setCursor(P(x, y))
  local clicked = ui.invisibleButton(id, vec2(w * SX, h * SY))
  local hov, act = ui.itemHovered(), ui.itemActive()

  rect(x - 1, y - 1, x + w + 1, y + h + 1, rgbm(0.05, 0.05, 0.07, 0.95), 2)
  local top = act and rgbm(0.14, 0.14, 0.16, 1) or (hov and rgbm(0.30, 0.29, 0.33, 1) or rgbm(0.22, 0.21, 0.24, 1))
  local bot = act and rgbm(0.08, 0.08, 0.10, 1) or rgbm(0.10, 0.10, 0.12, 1)
  ui.drawRectFilledMultiColor(P(x, y), P(x + w, y + h), top, top, bot, bot)
  ui.drawLine(P(x + 2, y + 1.5), P(x + w - 2, y + 1.5), lit and PAL.on or rgbm(1, 1, 1, 0.22), math.max(1, SX))
  icon(x + w / 2, y + h / 2, lit and PAL.on or rgbm(0.82, 0.81, 0.85, 1))

  return clicked
end

local function drawXamp()
  local tr, cat = currentTrack(), library[cfg.folder]
  local cur, dur = playbackTimes()
  local shown = cfg.showRemaining and math.max(0, dur - cur) or cur
  local bassPulse = (lvl[1] + lvl[2] + lvl[3] + lvl[4]) / 4

  -- Chassi de alumínio escovado Titanium / Champagne (estilo 1X-AMP-PROFESSIONAL)
  ui.drawRectFilledMultiColor(
    vec2(0, 0), vec2(BODY.w, BODY.h),
    rgbm(0.68, 0.66, 0.64, 1), rgbm(0.42, 0.41, 0.43, 1),
    rgbm(0.32, 0.31, 0.34, 1), rgbm(0.56, 0.54, 0.53, 1)
  )
  for yy = 2, 188, 2 do
    local a = (yy % 4 == 0) and 0.045 or 0.018
    ui.drawLine(P(0, yy), P(DW, yy), rgbm(1, 1, 1, a), math.max(0.6, SX * 0.8))
  end
  border(1, 1, DW - 1, DH - 1, rgbm(0.88, 0.86, 0.84, 0.55), 1.5)
  border(3, 3, DW - 3, DH - 3, rgbm(0.12, 0.12, 0.14, 0.75), 1)

  -- Cabeçalho esquerdo: 1X-AMP-PROFESSIONAL + divisor EFFECTS
  txt('1X-AMP-PROFESSIONAL', 10.2, 17, 11, rgbm(0.15, 0.15, 0.18, 0.85))
  txt('1X-AMP-PROFESSIONAL', 10.2, 16, 10, rgbm(0.95, 0.94, 0.96, 1))

  ui.drawLine(P(16, 33), P(55, 33), rgbm(0.90, 0.89, 0.92, 0.8), math.max(1, SX))
  ctext('EFFECTS', 9.5, 88, 33, rgbm(0.96, 0.95, 0.98, 1))
  ui.drawLine(P(121, 33), P(160, 33), rgbm(0.90, 0.89, 0.92, 0.8), math.max(1, SX))

  -- Matriz 3x3 de efeitos (16, 44)
  fxState[1] = cfg.realSpectrum
  for r = 0, 2 do
    for c = 0, 2 do
      local idx = r * 3 + c + 1
      local bx = 16 + c * 49
      local by = 44 + r * 26
      if fxBtnXamp('xamp_fx_' .. idx, bx, by, 45, 21, FX_LABELS[idx], fxState[idx]) then
        if idx == 1 then
          cfg.realSpectrum = not cfg.realSpectrum
          fxState[1] = cfg.realSpectrum
          if tr then startAnalysis(tr) end
        else
          fxState[idx] = not fxState[idx]
        end
      end
    end
  end

  -- Botão POWER (liga/desliga reprodução) + Chaves seletoras SHUF e OPTIONS/REP
  if fxBtnXamp('xamp_pwr', 16, 146, 46, 30, 'POWER', state ~= 'stopped') then
    if state == 'stopped' then doPlay() else stopPlayback() end
  end
  if toggleSwitchXamp('xamp_sw_shf', 86, 159, 'SHUF', cfg.shuffle) then
    cfg.shuffle = not cfg.shuffle
  end
  if toggleSwitchXamp('xamp_sw_rep', 122, 159, 'REPEAT', cfg.repeatAll) then
    cfg.repeatAll = not cfg.repeatAll
  end

  -- Visor CRT Central arredondado (172, 12 -> 402, 134)
  rect(169, 9, 405, 137, rgbm(0.14, 0.14, 0.16, 0.95), 9)
  rect(172, 12, 402, 134, rgbm(0.02, 0.02, 0.03, 1), 7)
  border(172, 12, 402, 134, rgbm(0.08, 0.08, 0.10, 1), 2, 7)

  ui.pushClipRect(P(173, 13), P(401, 133), true)

  -- Grade escura estilo Sonique Navigation Console ao fundo do CRT
  for gx = 185, 395, 18 do
    ui.drawLine(P(gx, 14), P(gx, 132), palA(0.05), math.max(0.6, SX * 0.7))
  end
  for gy = 22, 126, 16 do
    ui.drawLine(P(174, gy), P(400, gy), palA(0.05), math.max(0.6, SX * 0.7))
  end

  -- Cabeçalho interno estilo Sonique (Waveform 1.1 + nome da estação)
  rect(184, 15, 390, 26, palA(0.14), 2)
  txt('SONIQUE // MIDNIGHT PASS', 7.8, 188, 16, PAL.text)
  local stText = (cat and cat.name or 'TODAS') .. ' [' .. eqModeText(false) .. ']'
  txt(stText, 7.8, 386 - #stText * 4.5, 16, PAL.on)

  -- LOGO EXCLUSIVA DA EQUIPE MIDNIGHT SUMMIT NO CENTRO DO VISOR
  drawMidnightSummitCrest(287, 68, 0.88, 0.34 + 0.24 * bassPulse, bassPulse)

  -- Cortinas laterais de espectro vermelho/tema nas bordas esquerda e direita (estilo 1X-AMP)
  local curtainRows = 28
  for r = 1, curtainRows do
    local fy = (r - 1) / (curtainRows - 1)
    local env = math.sin(fy * math.pi)
    local bL = clamp(math.floor(fy * 12) + 1, 1, BARS)
    local bR = clamp(BARS - math.floor(fy * 12), 1, BARS)
    local wL = (3 + lvl[bL] * 18) * env
    local wR = (3 + lvl[bR] * 18) * env
    local yPos = 24 + fy * 92
    ui.drawLine(P(174, yPos), P(174 + wL, yPos), PAL.on, math.max(1, 1.8 * SX))
    ui.drawLine(P(400 - wR, yPos), P(400, yPos), PAL.on, math.max(1, 1.8 * SX))
  end

  -- Osciloscópio duplo de alta resolução (1X-AMP + Sonique dual-wave)
  local midWaveY = 72
  local stepsW = 64
  local px1, py1, px2, py2
  for s = 0, stepsW do
    local fx = s / stepsW
    local wx = 182 + fx * 210
    local bIdx = clamp(math.floor(fx * (BARS - 1)) + 1, 1, BARS)
    local env = math.sin(fx * math.pi)
    local amp = (state == 'playing') and lvl[bIdx] or 0.03
    local w1 = math.sin(clock * 28 + s * 0.95) * math.cos(clock * 11 - s * 0.35) * amp * 24 * env
    local w2 = math.cos(clock * 21 - s * 0.70) * amp * 16 * env
    local y1 = clamp(midWaveY + w1, 28, 108)
    local y2 = clamp(midWaveY + w2, 28, 108)
    if s > 0 then
      ui.drawLine(P(px2, py2), P(wx, y2), PAL.wave2, math.max(1, 1.2 * SX))
      ui.drawLine(P(px1, py1), P(wx, y1), PAL.on, math.max(1.2, 1.8 * SX))
    end
    px1, py1, px2, py2 = wx, y1, wx, y2
  end

  -- Barra pontilhada "track progress" estilo Sonique + Marquee da música
  local dotsProg = 28
  local progFrac = (dur > 0) and clamp01(cur / dur) or 0
  for d = 0, dotsProg - 1 do
    local df = d / (dotsProg - 1)
    local dx = 186 + df * 202
    ui.drawCircleFilled(P(dx, 105), 1.5 * SX, (df <= progFrac) and PAL.on or PAL.segOff, 6)
  end

  drawMarquee(marqueeText(), 9.2, 184, 109, 390, 121, PAL.text)

  -- Rodapé digital vermelho/tema estilo 1X-AMP (Ano/Faixa | Tempo | Bitrate | Sample Rate)
  txt(string.format('TRK %02d', current), 8.5, 184, 122, PAL.on)
  ctext(fmtTimeSonique(shown), 8.8, 266, 126, PAL.on)
  txt('320 KB/S', 8.2, 314, 122, PAL.dim)
  txt('44100 HZ', 8.2, 356, 122, PAL.dim)

  ui.popClipRect()

  -- Clique no visor alterna tempo decorrido / restante
  ui.setCursor(P(174, 14))
  if ui.invisibleButton('xamp_crt_clk', vec2(226 * SX, 118 * SY)) then
    cfg.showRemaining = not cfg.showRemaining
  end

  -- Barra de Seek com alça ranhurada abaixo do visor
  seekBarXamp(192, 140, 190, 8)

  -- Fileira de 7 botões chanfrados de transporte na base (estilo 1X-AMP)
  local tby = 152
  if transportBtnXamp('x_play',  150, tby, 40, 24, iconPlay,    state == 'playing') then doPlay() end
  if transportBtnXamp('x_pause', 194, tby, 40, 24, iconPause,   state == 'paused') then doPause() end
  if transportBtnXamp('x_stop',  238, tby, 40, 24, iconStop,    state == 'stopped') then stopPlayback() end
  if transportBtnXamp('x_prev',  282, tby, 38, 24, iconPrev,    false) then prevTrack() end
  if transportBtnXamp('x_next',  322, tby, 38, 24, iconNext,    false) then nextTrack(false) end
  if transportBtnXamp('x_dirm',  364, tby, 38, 24, iconFastRew, false) then stepFolder(-1) end
  if transportBtnXamp('x_dirp',  404, tby, 38, 24, iconFastFwd, false) then stepFolder(1) end

  -- Grande Dial Rotativo de Volume à direita (474, 74)
  drawXampKnob(474, 74, 44)

  -- Botão canto superior direito (alterna skins rapidamente)
  if fxBtnXamp('xamp_skin_btn', 536, 12, 14, 13, 'v', false) then
    cfg.skin = (cfg.skin % 5) + 1
  end

  -- Emblema gravado no metal inferior direito: MIDNIGHT SUMMIT + 1X-AMP + Conector Dourado P2
  rect(448, 149, 530, 177, rgbm(0.16, 0.16, 0.19, 0.92), 3)
  border(448, 149, 530, 177, rgbm(0.78, 0.78, 0.82, 0.55), 1, 3)
  ctext('MIDNIGHT SUMMIT', 7.5, 489, 156, PAL.on)
  ctext('峠 MASTERS // AMP', 7.0, 489, 168, rgbm(0.86, 0.87, 0.90, 0.9))

  -- Jack P2 dourado (canto inferior direito)
  local jx, jy = 543, 165
  ui.drawCircleFilled(P(jx, jy), 6.5 * SX, rgbm(0.85, 0.68, 0.22, 1), 20)
  ui.drawCircle(P(jx, jy), 6.5 * SX, rgbm(0.98, 0.88, 0.50, 1), 20, math.max(1, 1.3 * SX))
  ui.drawCircleFilled(P(jx, jy), 3.2 * SX, rgbm(0.06, 0.06, 0.08, 1), 16)
end

--------------------------------------------------------------------------------
-- JANELA PRINCIPAL (responsiva, corpo preenche a janela inteira)
--------------------------------------------------------------------------------
function script.windowMain(dt)
  updatePalette()

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

  local s = math.max(math.min(winW / DW, winH / DH), 0.15)
  SX, SY = s, s
  OX = (winW - DW * s) * 0.5
  OY = (winH - DH * s) * 0.5

  pcall(ui.pushClipRect, vec2(0, 0), vec2(winW, winH), false)

  ui.pushDWriteFont('Consolas')
  if cfg.skin == 2 then
    drawRadio()
  elseif cfg.skin == 3 then
    drawBZR()
  elseif cfg.skin == 4 then
    drawAimp()
  elseif cfg.skin == 5 then
    drawXamp()
  else
    drawWinamp()
  end
  ui.popDWriteFont()

  pcall(ui.popClipRect)

  ui.setCursor(vec2(0, 0))
  ui.dummy(vec2(1, 1))
end

--------------------------------------------------------------------------------
-- JANELA DA PLAYLIST (v3.2)
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
-- JANELA DE CONFIGURAÇÃO (5 Skins + RGB/HSV + controles FFmpeg)
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

  ui.text('TEMA (5 SKINS)')
  if ui.radioButton('1. Winamp Classic', cfg.skin == 1) then cfg.skin = 1 end
  ui.sameLine()
  if ui.radioButton('2. Radio Automotivo', cfg.skin == 2) then cfg.skin = 2 end
  if ui.radioButton('3. BZR Studio (@MAX)', cfg.skin == 3) then cfg.skin = 3 end
  ui.sameLine()
  if ui.radioButton('4. AIMP Deck (JetAudio)', cfg.skin == 4) then cfg.skin = 4 end
  if ui.radioButton('5. Midnight X-AMP (Midnight Summit)', cfg.skin == 5) then cfg.skin = 5 end

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

  -- Pré-visualização ao vivo
  for i = 1, BARS do
    if state == 'playing' then
      demoL[i] = lvl[i]
      demoP[i] = peak[i]
    else
      local val = 0.5 + 0.5 * math.sin(clock * (1.5 + i * 0.37) + i)
      demoL[i] = val * (1 - 0.5 * (i - 1) / BARS)
      demoP[i] = math.min(1, demoL[i] + 0.12)
    end
  end

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
  ui.text('ESPECTRO REAL (FFMPEG)')
  if ui.checkbox('Usar ffmpeg (espectro no ritmo real da musica)', cfg.realSpectrum) then
    cfg.realSpectrum = not cfg.realSpectrum
    local tr = currentTrack()
    if tr then startAnalysis(tr) end
  end
  ui.setNextItemWidth(w)
  local ffp = ui.inputText('##ffp', cfg.ffmpeg)
  if type(ffp) == 'string' and ffp ~= cfg.ffmpeg then cfg.ffmpeg = ffp end
  ui.setNextItemWidth(w)
  v, ch = ui.slider('##sen', cfg.sensitivity, -12, 30, 'Sensibilidade FFT: %.0f dB')
  if ch then cfg.sensitivity = math.floor(v + 0.5) end
  if ui.button('Reprocessar faixa atual', vec2(w, 0)) then
    local tr = currentTrack()
    if tr then startAnalysis(tr) end
  end

  local statusMsg = ''
  if not cfg.realSpectrum then statusMsg = 'Status: FFmpeg desligado (usando modo pseudo-ritmico)'
  elseif pcm.status == 'ready' then statusMsg = 'Status: Espectro real ativo (FFT)'
  elseif pcm.status == 'decoding' then statusMsg = 'Status: Decodificando faixa de audio...'
  elseif pcm.status == 'missing' then statusMsg = 'Status: ffmpeg.exe nao encontrado em ' .. cfg.ffmpeg
  elseif pcm.status == 'error' then statusMsg = 'Status: Erro no ffmpeg (' .. pcm.msg .. ')'
  else statusMsg = 'Status: Aguardando musica tocar' end
  ui.textWrapped(statusMsg)

  ui.separator()
  ui.text('PULSO DO VISUALIZADOR (FALLBACK PSEUDO-RITMICO)')
  ui.setNextItemWidth(w)
  v, ch = ui.slider('##bpm', cfg.bpmManual, 0, 200, cfg.bpmManual < 60 and 'BPM: automatico' or 'BPM: %.0f')
  if ch then cfg.bpmManual = (v < 60) and 0 or math.floor(v + 0.5) end
  ui.setNextItemWidth(w)
  v, ch = ui.slider('##int', cfg.intensity * 100, 30, 150, 'Intensidade: %.0f%%')
  if ch then cfg.intensity = v / 100 end
  ui.textWrapped('Usado quando o FFmpeg esta desligado ou enquanto a faixa ainda esta sendo decodificada.')
end

-- Aliases globais para compatibilidade com qualquer configuração de manifest.ini
windowMain = script.windowMain
windowPlaylist = script.windowPlaylist
windowConfig = script.windowConfig
update = script.update

--------------------------------------------------------------------------------
-- inicialização
--------------------------------------------------------------------------------
pcall(io.createDir, CACHE)
for _, f in ipairs(safe(function() return io.scanDir(CACHE, '*.pcm') end) or {}) do
  pcall(io.deleteFile, CACHE .. '/' .. f)
end

initFFT()
if not fileExists(cfg.ffmpeg) then
  local alt = APP_DIR .. '/bin/ffmpeg.exe'
  if fileExists(alt) then cfg.ffmpeg = alt end
end

math.randomseed(os.time())
rescan()
updatePalette()