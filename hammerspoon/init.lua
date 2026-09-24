require("hs.ipc")

-- Ajustes rapidos: si el scroll cambia de escritorio al reves, pon SCROLL_INVERT = true.
local SCROLL_INVERT = false
local SCROLL_COOLDOWN = 0.28
local DOCK_FALLBACK_STRIP = 6
-- La raiz del repo se deduce de donde apunta el enlace ~/.hammerspoon/init.lua, asi que el
-- repositorio puede vivir en cualquier carpeta y con cualquier nombre.
local REPO = (hs.fs.pathToAbsolute(hs.configdir .. "/init.lua") or ""):match("^(.*)/hammerspoon/init%.lua$")
    or (os.getenv("HOME") .. "/code/projects/mac-muscle-memory")
local SPACESWITCH = REPO .. "/helper/spaceswitch"
local SPACESWITCH_GAP = "20"
local NOSWOOSH = os.getenv("HOME") .. "/Applications/noswoosh.app/Contents/MacOS/noswoosh"

-- El cambio de escritorio es instantaneo, asi que no queda ninguna pista visual de hacia
-- que lado te has movido. Estas constantes dibujan un barrido en la direccion del cambio.
-- HINT_ENABLED = false lo desactiva; HINT_DURATION es el unico numero que querras tocar.
local HINT_ENABLED = true
local HINT_DURATION = 0.114
local HINT_ALPHA = 0.42
local HINT_FPS = 120

-- Un barrido por pantalla, creado una sola vez y reutilizado: construirlos en cada cambio
-- costaria mas que la propia animacion.
local hintCanvases = nil
local hintTimer = nil

local function buildHintCanvases()
    local canvases = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local f = screen:fullFrame()
        local c = hs.canvas.new(f)
        -- Un degradado, no un panel solido: con un borde duro el barrido entra y sale de
        -- golpe y se percibe como un parpadeo en vez de como movimiento.
        c:appendElements({
            type = "rectangle",
            action = "fill",
            fillGradient = "linear",
            fillGradientAngle = 0,
            fillGradientColors = {
                { white = 0, alpha = 1 },
                { white = 0, alpha = 0 },
            },
            frame = { x = 0, y = 0, w = f.w, h = f.h },
        })
        -- Sin esto el barrido se queda en el escritorio de origen y no se ve al llegar.
        c:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
        c:level(hs.canvas.windowLevels.overlay)
        c:clickActivating(false)
        c:alpha(0)
        canvases[#canvases + 1] = { canvas = c, width = f.w, height = f.h }
    end
    return canvases
end

local function showSwitchHint(direction)
    if not HINT_ENABLED then return end
    if not hintCanvases then hintCanvases = buildHintCanvases() end
    if hintTimer then hintTimer:stop() end

    -- El contenido se mueve al contrario que el escritorio: ir al siguiente (derecha)
    -- desplaza lo que ves hacia la izquierda.
    local sign = (direction < 0) and 1 or -1

    for _, h in ipairs(hintCanvases) do
        h.canvas:alpha(0)
        h.canvas[1].frame = { x = -sign * h.width, y = 0, w = h.width, h = h.height }
        h.canvas[1].fillGradientAngle = (sign > 0) and 0 or 180
        h.canvas:show()
    end

    local started = hs.timer.secondsSinceEpoch()
    hintTimer = hs.timer.doEvery(1 / HINT_FPS, function()
        local progress = (hs.timer.secondsSinceEpoch() - started) / HINT_DURATION
        if progress >= 1 then
            hintTimer:stop()
            hintTimer = nil
            for _, h in ipairs(hintCanvases) do
                h.canvas:alpha(0)
                h.canvas:hide()
            end
            return
        end

        -- Desacelera al final, que es lo que hace que se lea como un movimiento y no como
        -- un salto. Y la opacidad sube y baja en seno, de modo que empieza y acaba en cero:
        -- sin cortes bruscos no hay parpadeo.
        local eased = 1 - (1 - progress) ^ 3
        local alpha = math.sin(math.pi * progress) * HINT_ALPHA

        for _, h in ipairs(hintCanvases) do
            h.canvas:alpha(alpha)
            h.canvas[1].frame = {
                x = sign * (eased - 1) * h.width,
                y = 0,
                w = h.width,
                h = h.height,
            }
        end
    end)
end

-- Las pantallas cambian de resolucion o se conectan y desconectan; los lienzos cacheados
-- dejarian de cubrirlas.
hintScreenWatcher = hs.screen.watcher.new(function()
    if hintTimer then hintTimer:stop(); hintTimer = nil end
    if hintCanvases then
        for _, h in ipairs(hintCanvases) do h.canvas:delete() end
        hintCanvases = nil
    end
end)
hintScreenWatcher:start()

-- Un hs.task sin referencia viva puede ser recolectado antes de ejecutarse, y entonces el
-- cambio de escritorio falla de forma intermitente. Mantenemos la referencia hasta que
-- termina.
local pendingTasks = {}
local function runTask(path, args, done)
    local task
    task = hs.task.new(path, function(...)
        pendingTasks[task] = nil
        if done then done(...) end
    end, args)
    pendingTasks[task] = true
    task:start()
end

-- hs.eventtap no sirve para este atajo: pone la bandera de Control en la flecha pero nunca
-- pulsa Control de verdad, y el sistema no lo reconoce. Hay que emitir un key down real de
-- Control y luego la flecha limpia. Eso hace el binario spaceswitch, en unos 127 ms frente a
-- los 450 ms de cliclick, que es lo que se notaba como retardo antes de la animacion.
-- hs.spaces.gotoSpace tampoco sirve: falla con "no display with specified id found" porque
-- el Dock registra el monitor como "Main" en vez de su UUID.
-- noswoosh cambia de escritorio en unos 130 ms contra los 1165 ms de la animacion nativa,
-- que macOS 27 ya no deja configurar por ningun ajuste. Mantiene los escritorios nativos
-- compartidos entre las tres pantallas. spaceswitch queda como respaldo si no esta instalado.
local useNoswoosh = hs.fs.attributes(NOSWOOSH) ~= nil

local function pressSpaceShortcut(direction)
    local key = (direction < 0) and "left" or "right"
    showSwitchHint(direction)
    if useNoswoosh then
        runTask(NOSWOOSH, { key })
    else
        runTask(SPACESWITCH, { key, SPACESWITCH_GAP })
    end
end

local function spaceNeighbour(screen, direction)
    local spaces = hs.spaces.spacesForScreen(screen)
    if not spaces then return nil end

    local current = hs.spaces.activeSpaceOnScreen(screen)
    local index = nil
    for i, id in ipairs(spaces) do
        if id == current then
            index = i
            break
        end
    end
    if not index then return nil end

    local target = index + direction
    if target < 1 or target > #spaces then return nil end
    return spaces[target]
end

-- Mover la ventana enfocada al escritorio de al lado, y seguirla.
-- Ctrl+Cmd+Shift+Left / Ctrl+Cmd+Shift+Right. Era Ctrl+Shift+flecha hasta 2026-09-24; se movio
-- junto con el cambio de escritorio (Ctrl+Cmd+flecha) para que los dos vayan a juego.

-- hs.spaces.moveWindowToSpace devuelve exito pero no mueve nada en macOS 27, asi que
-- replicamos el gesto manual: agarrar la ventana por la barra de titulo y cambiar de
-- escritorio mientras sigue agarrada, que es como lo hace macOS de forma nativa.
local SPACE_MOVE_HOLD = 0.06        -- segundos que se sigue sujetando tras cambiar la vista
local SPACE_MOVE_TIMEOUT = 3        -- si la vista no cambia en este tiempo, se suelta igual
local spaceMoveBusy = false

local function moveFocusedWindowToSpace(direction)
    if spaceMoveBusy then return end
    local win = hs.window.focusedWindow()
    if not win then return end

    -- Una ventana en pantalla completa real ya ocupa su propio escritorio, asi que no
    -- hay nada que mover y ademas no tiene barra de titulo que agarrar.
    if win:isFullScreen() then
        hs.alert.show("En pantalla completa no se puede mover: ya es su propio escritorio")
        return
    end

    local screen = win:screen()
    if not spaceNeighbour(screen, direction) then return end
    if not hs.fs.attributes(SPACESWITCH) then
        hs.alert.show("Falta helper/spaceswitch: ejecuta bin/apply.sh del repo")
        return
    end
    spaceMoveBusy = true

    -- El centro de la barra de titulo suele estar ocupado (el buscador en Cursor, una
    -- pestana en Chrome) y ahi el clic abre un desplegable en vez de arrastrar, cosa que
    -- solo se nota con la ventana maximizada. Al 85% del ancho casi siempre hay hueco.
    local frame = win:frame()
    local pt = { x = math.floor(frame.x + frame.w * 0.85), y = math.floor(frame.y + 10) }
    local grab = { x = pt.x + 3, y = pt.y }
    local origin = hs.mouse.absolutePosition()
    local before = hs.spaces.activeSpaceOnScreen(screen)
    local T = hs.eventtap.event.types

    -- Antes esto lo hacia cliclick con esperas fijas y tardaba ~700 ms en mover la ventana y
    -- ~980 ms en llegar la vista, mas lo que tardaras en soltar las teclas. Ahora (2026-09-24):
    --   1. Clic en la barra de titulo y tres eventos de arrastre de 1 px. Sin esos eventos
    --      macOS no considera la ventana agarrada y cambia de escritorio sin ella: medido.
    --   2. Atajo nativo Ctrl+Cmd+flecha con spaceswitch, sin esperar. noswoosh NO sirve aqui:
    --      no cambia de escritorio mientras hay un arrastre en curso (probado dos veces).
    --   3. Se suelta en cuanto la vista ha cambiado, en vez de tras un tiempo fijo.
    -- Resultado medido: ~356 ms hasta la vista, 6 de 6 movimientos correctos.
    --
    -- Ya NO se espera a que sueltes Ctrl+Cmd+Shift: spaceswitch pone las banderas explicitas
    -- en cada evento y las teclas que sigues pulsando no lo contaminan. Probado manteniendo
    -- Ctrl+Cmd+Shift pulsados durante el movimiento.
    hs.mouse.absolutePosition(pt)
    hs.eventtap.event.newMouseEvent(T.leftMouseDown, pt):post()
    for i = 1, 3 do
        hs.eventtap.event.newMouseEvent(T.leftMouseDragged, { x = pt.x + i, y = pt.y }):post()
    end

    showSwitchHint(direction)
    runTask(SPACESWITCH, { (direction < 0) and "left" or "right", "5" })

    local started = hs.timer.secondsSinceEpoch()
    local poll
    poll = hs.timer.doEvery(0.005, function()
        local changed = hs.spaces.activeSpaceOnScreen(screen) ~= before
        if not changed and hs.timer.secondsSinceEpoch() - started < SPACE_MOVE_TIMEOUT then return end
        poll:stop()
        hs.timer.doAfter(SPACE_MOVE_HOLD, function()
            hs.eventtap.event.newMouseEvent(T.leftMouseUp, grab):post()
            hs.mouse.absolutePosition(origin)
            spaceMoveBusy = false
        end)
    end)
end

hs.hotkey.bind({"ctrl", "cmd", "shift"}, "left", function() moveFocusedWindowToSpace(-1) end)
hs.hotkey.bind({"ctrl", "cmd", "shift"}, "right", function() moveFocusedWindowToSpace(1) end)

-- Mover la ventana enfocada al monitor de al lado.
-- Ctrl+Option+Left / Ctrl+Option+Right ("alt" en Hammerspoon es la tecla Option; en un teclado
-- Windows en modo Mac es la tecla Windows, no la Alt).
--
-- Esto no tiene nada que ver con los escritorios: cambiar de monitor es mover un marco por
-- la geometria de las pantallas, asi que no depende de ninguna de las APIs rotas.

local function moveWindowToScreen(direction)
    local win = hs.window.focusedWindow()
    if not win then return end

    if win:isFullScreen() then
        hs.alert.show("En pantalla completa no se puede cambiar de monitor")
        return
    end

    local current = win:screen()
    local target = (direction < 0) and current:toWest() or current:toEast()
    if not target then return end

    -- Reescala proporcionalmente, que es lo que se quiere entre pantallas de distinta
    -- resolucion, y con duracion cero para que no haya animacion de por medio.
    win:moveToScreen(target, false, true, 0)
end

hs.hotkey.bind({"ctrl", "alt"}, "left", function() moveWindowToScreen(-1) end)
hs.hotkey.bind({"ctrl", "alt"}, "right", function() moveWindowToScreen(1) end)

-- Bloquear la sesion con Ctrl+Cmd+L, al estilo del Win+L / Ctrl+Alt+L de Windows y Ubuntu.
-- Primero fue Ctrl+Alt+L; se probo, funcionaba, y se prefirio Ctrl+Cmd+L (2026-09-24).
-- Ningun atajo de sistema usa esa combinacion. El nativo de macOS es Ctrl+Cmd+Q y sigue ahi.
-- Bloquea de verdad, no cierra la sesion: usa SACLockScreenImmediate, la misma llamada que
-- Ctrl+Cmd+Q, y la contrasena se pide al instante ("screenLock delay is immediate").
hs.hotkey.bind({"ctrl", "cmd"}, "l", function()
    hs.caffeinate.lockScreen()
end)

-- Ctrl+Cmd+T abre una ventana nueva de Ghostty, al estilo del Ctrl+Alt+T de Ubuntu.
-- Si Ghostty no esta abierto, lanzarlo ya crea la primera ventana; si lo esta, se pide
-- una ventana nueva por el menu en vez de limitarse a traerlo al frente.
hs.hotkey.bind({"ctrl", "cmd"}, "t", function()
    local ghostty = hs.application.get("com.mitchellh.ghostty")
    if not ghostty then
        hs.application.launchOrFocusByBundleID("com.mitchellh.ghostty")
        return
    end
    ghostty:activate()
    ghostty:selectMenuItem({"File", "New Window"})
end)

-- Copiar, pegar, cortar y deshacer tambien con Ctrl, ademas del Cmd nativo, EN TODAS LAS APPS.
-- Y Ctrl+Shift+V pega sin formato.
--
-- Decision explicita del usuario (2026-09-23): lo quiere en cualquier aplicacion, sin excepciones.
-- El precio, que conoce: en un terminal Ctrl+C ya NO interrumpe el proceso en ejecucion, porque
-- se convierte en copiar antes de que el shell lo reciba. Un comando colgado hay que cortarlo
-- de otra forma (cerrar la pestana, o cambiar el caracter de interrupcion con `stty intr`).
-- Lo mismo con Ctrl+Z: en un terminal ya NO suspende el proceso (SIGTSTP), se convierte en
-- deshacer. Ctrl+Shift+V en cambio coincide con el pegar de los terminales de Linux.
-- Ctrl+B tampoco llega al terminal: deja de ser el prefijo de tmux y el "atras un caracter"
-- de readline.
-- Y Ctrl+A ya no lleva al principio de la linea, ni en el terminal (readline) ni en los campos
-- de texto de macOS, que tambien lo usaban asi. Para eso queda Cmd+Flecha izquierda o Inicio.
--
-- Para recuperar el comportamiento normal en una app basta con volver a ponerla en la lista:
--   CLIPBOARD_PASSTHROUGH_APPS = { ["Terminal"] = true, ["iTerm2"] = true, ["Cursor"] = true }
local CLIPBOARD_REMAP_ENABLED = true
local CLIPBOARD_PASSTHROUGH_APPS = {}

-- Tecla -> que hacer con Ctrl a secas (plain) y con Ctrl+Shift (shift).
-- Ctrl+Z deshace y Ctrl+A selecciona todo (anadidos 2026-09-23). Ctrl+Shift+V pega sin
-- formato, como en Linux.
local clipboardShortcuts = {
    [hs.keycodes.map.c] = { plain = "c" },
    [hs.keycodes.map.v] = { plain = "v", shift = "plainpaste" },
    [hs.keycodes.map.x] = { plain = "x" },
    [hs.keycodes.map.z] = { plain = "z" },
    [hs.keycodes.map.a] = { plain = "a" },
    -- Ctrl+B pone en negrita el texto seleccionado, como en Windows y Ubuntu (2026-09-24).
    [hs.keycodes.map.b] = { plain = "b" },

    -- Moverse y seleccionar por palabras con Ctrl, como en Ubuntu y Windows (2026-09-24). En
    -- macOS eso es Option: Ctrl+flecha -> Option+flecha, Ctrl+Shift+flecha -> Option+Shift+flecha.
    -- Posible desde que Ctrl+flecha dejo de cambiar de escritorio (ahora es Ctrl+Cmd+flecha) y
    -- Ctrl+Shift+flecha dejo de mover ventanas (ahora es Ctrl+Cmd+Shift+flecha).
    -- Una accion en tabla es { modificadores, tecla }; una en texto es Cmd+tecla.
    [hs.keycodes.map.left]  = { plain = { { "alt" }, "left" },  shift = { { "alt", "shift" }, "left" } },
    [hs.keycodes.map.right] = { plain = { { "alt" }, "right" }, shift = { { "alt", "shift" }, "right" } },
}

-- Las flechas llegan siempre con la bandera fn puesta (el teclado las marca asi), de modo que
-- para ellas fn no significa "otro atajo" y no se puede usar para descartarlas.
local arrowKeyCodes = {
    [hs.keycodes.map.left] = true,
    [hs.keycodes.map.right] = true,
}

-- Pegar sin formato, igual en todas las apps.
--
-- macOS no tiene un atajo universal para esto: Chrome y las apps nativas usan Cmd+Alt+Shift+V,
-- Slack usa Cmd+Shift+V, y Cursor/VS Code no tienen ninguno. En vez de mantener una tabla por
-- app, se deja en el portapapeles solo el texto, se pega con Cmd+V normal, y despues se
-- restaura el contenido original con todos sus formatos, para que el siguiente Ctrl+V vuelva a
-- pegar con formato.
--
-- La restauracion espera un poco porque la app lee el portapapeles de forma asincrona tras
-- recibir Cmd+V; restaurar al instante haria que pegase el contenido con formato. Y solo se
-- restaura si nadie ha tocado el portapapeles entretanto: si copias algo en ese margen, gana
-- lo que copiaste.
local PLAIN_PASTE_RESTORE_DELAY = 0.4

-- Pega un texto cualquiera y deja el portapapeles como estaba. Lo usan el pegado sin formato
-- y el pegado de la seleccion primaria con el boton central.
local function pastePreservingClipboard(text, app)
    local saved = hs.pasteboard.readAllData()
    hs.pasteboard.setContents(text)
    local ours = hs.pasteboard.changeCount()
    hs.eventtap.keyStroke({ "cmd" }, "v", 0, app)
    hs.timer.doAfter(PLAIN_PASTE_RESTORE_DELAY, function()
        if saved and hs.pasteboard.changeCount() == ours then
            hs.pasteboard.writeAllData(saved)
        end
    end)
end

local function pastePlain(app)
    local text = hs.pasteboard.readString()
    if not text then
        -- Sin texto (una imagen, un fichero): no hay formato que quitar, pegado normal.
        hs.eventtap.keyStroke({ "cmd" }, "v", 0, app)
        return
    end
    pastePreservingClipboard(text, app)
end

-- Modificar las banderas del evento con setFlags y dejarlo pasar NO funciona: el sistema lo
-- entrega con el Ctrl original. Hay que consumirlo y emitir uno nuevo con Cmd. El evento que
-- emitimos ya no lleva Ctrl, asi que no vuelve a entrar por aqui y no hay bucle.
clipboardTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if not CLIPBOARD_REMAP_ENABLED then return false end

    local entry = clipboardShortcuts[event:getKeyCode()]
    if not entry then return false end

    -- Ctrl, o Ctrl+Shift. Con Cmd, Alt o Fn encima es otro atajo distinto y no nos corresponde
    -- (salvo fn en las flechas, que siempre la llevan).
    local flags = event:getFlags()
    local fnMatters = not arrowKeyCodes[event:getKeyCode()]
    if not flags.ctrl or flags.cmd or flags.alt or (fnMatters and flags.fn) then return false end

    local action = flags.shift and entry.shift or (not flags.shift and entry.plain)
    if not action then return false end

    local app = hs.application.frontmostApplication()
    if app and CLIPBOARD_PASSTHROUGH_APPS[app:name()] then return false end

    if action == "plainpaste" then
        pastePlain(app)
        return true
    end

    -- Se envia directamente a la aplicacion en vez de al flujo global: el Ctrl que el usuario
    -- todavia tiene pulsado se fusionaria con el Cmd inyectado y el atajo no se reconoceria.
    if type(action) == "table" then
        hs.eventtap.keyStroke(action[1], action[2], 0, app)
    else
        hs.eventtap.keyStroke({ "cmd" }, action, 0, app)
    end
    return true
end)

clipboardTap:start()

-- Borrar en Finder con Supr y Shift+Supr, como en Ubuntu (2026-09-24).
--   Supr        -> mover a la Papelera        (Cmd+Retroceso en macOS)
--   Shift+Supr  -> eliminar inmediatamente    (Option+Cmd+Retroceso), que pide confirmacion
--
-- Solo en Finder, y nunca mientras se esta escribiendo: renombrando un archivo o en el buscador,
-- Supr tiene que seguir borrando el caracter de la derecha. Eso se decide preguntando por
-- accesibilidad que elemento tiene el foco; si es un campo de texto, no se toca nada.
--
-- Supr llega con la bandera fn puesta, igual que las flechas, asi que fn no descarta el evento.
local FINDER_DELETE_ENABLED = true

local function finderIsEditingText()
    local ok, focused = pcall(function()
        return hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
    end)
    if not ok or not focused then return false end
    local role = focused:attributeValue("AXRole")
    return role == "AXTextField" or role == "AXTextArea" or role == "AXComboBox" or role == "AXSearchField"
end

finderDeleteTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if not FINDER_DELETE_ENABLED then return false end
    if event:getKeyCode() ~= hs.keycodes.map.forwarddelete then return false end

    local flags = event:getFlags()
    if flags.cmd or flags.alt or flags.ctrl then return false end

    local app = hs.application.frontmostApplication()
    if not app or app:bundleID() ~= "com.apple.finder" then return false end
    if finderIsEditingText() then return false end

    if flags.shift then
        hs.eventtap.keyStroke({ "alt", "cmd" }, "delete", 0, app)
    else
        hs.eventtap.keyStroke({ "cmd" }, "delete", 0, app)
    end
    return true
end)

finderDeleteTap:start()

-- La tecla Impr Pant abre el recorte, lo guarda Y lo copia al portapapeles.
--
-- macOS no tiene concepto de tecla Impr Pant. Lo que hace el teclado usado aqui en su capa Mac
-- es emitir Cmd+Shift+3, que es el atajo nativo de "captura de pantalla completa a fichero".
-- Medido con un sniffer de eventos: cuatro pulsaciones, cuatro Cmd+Shift+3 limpios. No es una
-- tecla desconocida, es un atajo corriente, y por eso se puede interceptar como cualquier otro.
--
-- Lo que se quiere es distinto de lo que hace ese atajo: recorte en vez de pantalla entera,
-- y las DOS salidas a la vez, fichero y portapapeles.
--
-- screencapture no sabe hacer las dos cosas de una vez: -c manda al portapapeles e ignora la
-- ruta del fichero. Asi que se captura a fichero y despues se carga ese fichero al
-- portapapeles. El orden importa: el fichero es el original, el portapapeles es la copia.
--
-- Sin -x, para que suene el obturador. Ese sonido es la confirmacion de que la captura se hizo,
-- que es justo lo que se echa en falta cuando el resultado es invisible por irse al portapapeles.
--
-- Devolver true consume el evento y macOS ya no dispara su propia captura. Comprobado con
-- numeros, no por impresion: cuatro pulsaciones, cuatro intercepciones, y el Escritorio se
-- quedo en 34 ficheros antes y 34 despues, con un PNG en el portapapeles.
--
-- Esta via se eligio frente a reasignar los atajos de sistema (symbolichotkeys), que tambien
-- era posible, porque es reversible borrando estas lineas y no toca nada del sistema. Editar
-- symbolichotkeys ya nos rompio cosas una vez: ver el aviso sobre `noswoosh setup` y los
-- atajos 79 y 81 en docs/macos-27-notes.md.
local SCREENSHOT_REMAP_ENABLED = true
-- Mientras una captura esta en marcha, la seleccion primaria no debe tocar el portapapeles:
-- el arrastre del recorte parece una seleccion de texto, y su "copiar y restaurar" machacaba
-- la imagen recien copiada con el contenido anterior (2026-09-24).
screenshotInProgress = false
local SCREENSHOT_SOUND = true

-- Se lee del mismo ajuste del sistema que escribe bin/apply.sh, en vez de repetir la ruta aqui:
-- dos copias del mismo dato acaban discrepando. Se evalua una vez al cargar, asi que si cambias
-- la carpeta hay que recargar Hammerspoon.
local SCREENSHOT_DIR = (function()
    local out = hs.execute("defaults read com.apple.screencapture location 2>/dev/null")
    local dir = out and out:gsub("%s+$", "") or ""
    if dir == "" then dir = os.getenv("HOME") .. "/Desktop" end
    return dir
end)()

-- screencapture NO crea la carpeta que falta: vuelve a guardar en el Escritorio sin decir nada,
-- que se parece exactamente a que el ajuste se haya ignorado.
if not hs.fs.attributes(SCREENSHOT_DIR) then
    hs.fs.mkdir(SCREENSHOT_DIR)
end

-- El mismo formato de nombre que usa macOS, para que las capturas de la tecla y las de los
-- atajos nativos se ordenen juntas en la carpeta.
local function screenshotPath()
    return string.format("%s/Screenshot %s.png", SCREENSHOT_DIR, os.date("%Y-%m-%d at %H.%M.%S"))
end

-- Si se cancela con Esc, screencapture no escribe nada. En ese caso no se toca el portapapeles:
-- machacarlo con la captura anterior seria peor que no hacer nada.
local function copyShotToPasteboard(path, attempt)
    attempt = attempt or 1
    if not hs.fs.attributes(path) then
        -- El proceso puede terminar una fraccion de segundo antes de que el fichero este
        -- visible. Se reintenta un par de veces antes de darlo por cancelado.
        if attempt < 3 then
            hs.timer.doAfter(0.1, function() copyShotToPasteboard(path, attempt + 1) end)
        end
        return
    end
    local img = hs.image.imageFromPath(path)
    if img then hs.pasteboard.writeObjects(img) end
end

screenshotTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if not SCREENSHOT_REMAP_ENABLED then return false end

    if event:getKeyCode() ~= hs.keycodes.map["3"] then return false end

    -- Exactamente Cmd+Shift, ni mas ni menos. Ctrl+Cmd+Shift+3 es el atajo nativo de pantalla
    -- entera al portapapeles, y sigue siendo suyo.
    local flags = event:getFlags()
    if not (flags.cmd and flags.shift) or flags.ctrl or flags.alt or flags.fn then return false end

    local path = screenshotPath()
    local args = { "-i" }
    if not SCREENSHOT_SOUND then args[#args + 1] = "-x" end
    args[#args + 1] = path

    screenshotInProgress = true
    runTask("/usr/sbin/screencapture", args, function()
        copyShotToPasteboard(path)
        hs.timer.doAfter(1.0, function() screenshotInProgress = false end)
    end)
    return true
end)

screenshotTap:start()

-- Cambiar de escritorio haciendo scroll con el raton encima del Dock (estilo Ubuntu).

local dockAutohide = hs.execute("defaults read com.apple.dock autohide 2>/dev/null"):match("1") ~= nil

local function dockZone(screen)
    local full = screen:fullFrame()
    local usable = screen:frame()
    -- El Dock visible recorta la parte inferior del area utilizable; esa franja es su zona.
    local reserved = (full.y + full.h) - (usable.y + usable.h)

    if reserved > 2 then
        return full.x, full.x + full.w, full.y + full.h - reserved, full.y + full.h
    end
    -- Con el Dock oculto no reserva espacio, asi que usamos el borde inferior de la pantalla.
    if dockAutohide then
        return full.x, full.x + full.w, full.y + full.h - DOCK_FALLBACK_STRIP, full.y + full.h
    end
    return nil
end

local function mouseOverDock()
    local screen = hs.mouse.getCurrentScreen()
    if not screen then return false end

    local left, right, top, bottom = dockZone(screen)
    if not left then return false end

    local pos = hs.mouse.absolutePosition()
    return pos.x >= left and pos.x <= right and pos.y >= top and pos.y <= bottom
end

local lastSwitch = 0

dockScrollTap = hs.eventtap.new({ hs.eventtap.event.types.scrollWheel }, function(event)
    if not mouseOverDock() then return false end

    local delta = event:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)
    -- Devolvemos true siempre que el raton este sobre el Dock para que macOS no
    -- dispare ademas su propio Expose de aplicacion con el mismo gesto.
    if delta == 0 then return true end

    -- Un solo giro de rueda emite varios eventos; sin esta pausa saltaria varios escritorios.
    local now = hs.timer.secondsSinceEpoch()
    if now - lastSwitch < SCROLL_COOLDOWN then return true end
    lastSwitch = now

    local direction = (delta > 0) and -1 or 1
    if SCROLL_INVERT then direction = -direction end
    pressSpaceShortcut(direction)

    return true
end)

dockScrollTap:start()

-- Expuesto para probar desde la terminal: hs -c "dockScroll.switch(1)"
-- Seleccion primaria al estilo de Linux (2026-09-24): seleccionar texto lo copia a un
-- portapapeles APARTE, y el boton central del raton lo pega. Ctrl+C / Ctrl+V no se enteran.
--
-- Captura: tras un arrastre, un doble o triple clic, o un Shift+clic, se lee lo seleccionado.
-- Primero por accesibilidad (AXSelectedText), que no toca nada. Si la app no lo expone, como
-- las paginas web o los terminales, se hace un Cmd+C y se restaura el portapapeles al momento.
-- Solo se intenta si el foco esta en algo que contiene texto, para no copiar ficheros al
-- arrastrar en Finder ni nada parecido.
--
-- Pegado: solo si bajo el puntero hay algo editable (campo, area de texto, editor web) o una
-- app de PRIMARY_PASTE_ANYWHERE_APPS. En cualquier otro sitio el clic central sigue haciendo
-- lo suyo: abrir un enlace en otra pestana, cerrar una pestana. Como en Ubuntu, primero se
-- coloca el cursor donde esta el puntero y luego se pega.
local PRIMARY_ENABLED = true
-- Si el arrastre empieza sobre uno de estos, no es una seleccion de texto: mover una ventana,
-- una barra de desplazamiento, un separador. No se captura.
local PRIMARY_NOT_TEXT_ROLES = {
    AXWindow = true, AXToolbar = true, AXButton = true, AXScrollBar = true, AXSplitter = true,
    AXTabGroup = true, AXRadioButton = true, AXSlider = true, AXImage = true, AXMenuBar = true,
    AXMenuBarItem = true, AXDockItem = true, AXList = true, AXPopUpButton = true, AXCheckBox = true,
}
local PRIMARY_EDITABLE_ROLES = { AXTextArea = true, AXTextField = true, AXComboBox = true, AXSearchField = true }
-- Apps donde el boton central pega en cualquier punto de la ventana. Chrome y las apps Electron
-- (Cursor, VS Code) no exponen por accesibilidad si bajo el puntero hay un campo de texto o un
-- enlace, asi que por defecto NO pegan: romperia "abrir enlace en otra pestana" y "cerrar
-- pestana". Anadelas aqui si prefieres pegar siempre. Su bundle id: osascript -e 'id of app "X"'.
local PRIMARY_PASTE_ANYWHERE_APPS = { ["com.mitchellh.ghostty"] = true }
-- Apps donde nunca se captura: en Finder, arrastrar selecciona ficheros, no texto.
local PRIMARY_IGNORE_APPS = { ["com.apple.finder"] = true }

local primaryText = nil
-- Registro corto de lo que ha hecho la seleccion primaria, para diagnosticar sin adivinar:
--   hs -c 'return table.concat(dockScroll.primaryLog(), "\n")'
local primaryLog = {}
local function plog(msg)
    primaryLog[#primaryLog + 1] = os.date("%H:%M:%S ") .. msg
    if #primaryLog > 40 then table.remove(primaryLog, 1) end
end
local CURSORKIND = REPO .. "/helper/cursorkind"
local primaryDownAt = nil
local primarySwallowUp = false
local primaryCapturing = false
local P = hs.eventtap.event.properties
local MT = hs.eventtap.event.types

local function axFocused()
    local ok, el = pcall(function()
        return hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
    end)
    return ok and el or nil
end

local function selectedTextOf(el)
    if not el then return nil end
    local ok, t = pcall(function() return el:attributeValue("AXSelectedText") end)
    if ok and type(t) == "string" and #t > 0 then return t end
    return nil
end

local function elementAt(pos)
    if not pos then return nil end
    local ok, el = pcall(function() return hs.axuielement.systemElementAtPosition(pos) end)
    return ok and el or nil
end

-- Captura CUALQUIER texto seleccionado, este donde este: un campo, una pagina, una etiqueta, un
-- mensaje. Primero por accesibilidad, mirando el elemento con el foco y despues el que hay bajo
-- el puntero y sus contenedores, que es donde vive el texto no editable. Si nadie la expone, se
-- copia y se restaura el portapapeles.
local function capturePrimary(downAt, upAt)
    if primaryCapturing then return end
    if screenshotInProgress then plog("captura: omitida, hay una captura de pantalla en curso"); return end
    local app = hs.application.frontmostApplication()
    local bundle = app and app:bundleID()
    if bundle == "com.apple.screencaptureui" then return end
    if PRIMARY_IGNORE_APPS[bundle] then plog("captura: omitida en " .. tostring(bundle)); return end

    local startEl = elementAt(downAt)
    local startRole = startEl and startEl:attributeValue("AXRole")
    if startRole and PRIMARY_NOT_TEXT_ROLES[startRole] then
        plog("captura: omitida, el arrastre empezo sobre " .. startRole)
        return
    end

    local text = selectedTextOf(axFocused())
    if not text then
        local el = elementAt(upAt) or startEl
        for _ = 1, 6 do
            if not el then break end
            text = selectedTextOf(el)
            if text then break end
            local ok, parent = pcall(function() return el:attributeValue("AXParent") end)
            el = ok and parent or nil
        end
    end
    if text then
        primaryText = text
        plog("captura: por accesibilidad en " .. tostring(bundle) .. ", " .. #text .. " caracteres")
        return
    end

    -- Nadie expone la seleccion: se copia y se restaura el portapapeles.
    primaryCapturing = true
    local saved = hs.pasteboard.readAllData()
    local before = hs.pasteboard.changeCount()
    hs.eventtap.keyStroke({ "cmd" }, "c", 0, app)
    hs.timer.doAfter(0.15, function()
        if hs.pasteboard.changeCount() ~= before and not screenshotInProgress then
            local copied = hs.pasteboard.readString()
            if copied and #copied > 0 then primaryText = copied end
            if saved then hs.pasteboard.writeAllData(saved) end
            plog("captura: copiando en " .. tostring(bundle) .. ", " .. (copied and #copied or 0) .. " caracteres")
        else
            plog("captura: nada que copiar en " .. tostring(bundle) .. " (rol de inicio " .. tostring(startRole) .. ")")
        end
        primaryCapturing = false
    end)
end

-- Chrome y las apps Electron no dicen por accesibilidad que hay bajo el puntero. La forma del
-- cursor si: la "I" de texto sobre texto, la mano sobre enlaces, la flecha sobre pestanas.
local function cursorIsIBeam()
    if not hs.fs.attributes(CURSORKIND) then return false end
    local out = hs.execute(CURSORKIND) or ""
    return out:match("ibeam") ~= nil
end

local function editableUnder(pos)
    local ok, el = pcall(function() return hs.axuielement.systemElementAtPosition(pos) end)
    local app, role, bundle
    if ok and el then
        local pid = el:pid()
        app = pid and hs.application.applicationForPID(pid)
        bundle = app and app:bundleID()
        role = el:attributeValue("AXRole")
        if bundle and PRIMARY_PASTE_ANYWHERE_APPS[bundle] then return true, app, "app " .. bundle end
        if PRIMARY_EDITABLE_ROLES[role] or el:attributeValue("AXEditableAncestor") then return true, app, "rol " .. tostring(role) end
    end
    if cursorIsIBeam() then return true, app, "cursor de texto sobre " .. tostring(bundle) end
    return false, app, "no editable: " .. tostring(bundle) .. " rol " .. tostring(role)
end

primaryTap = hs.eventtap.new({ MT.leftMouseDown, MT.leftMouseUp, MT.otherMouseDown, MT.otherMouseUp }, function(event)
    if not PRIMARY_ENABLED or spaceMoveBusy then return false end
    local t = event:getType()

    if t == MT.leftMouseDown then
        primaryDownAt = event:location()
        return false
    end
    if t == MT.leftMouseUp then
        local pos = event:location()
        local clicks = event:getProperty(P.mouseEventClickState) or 1
        local moved = primaryDownAt and (math.abs(pos.x - primaryDownAt.x) + math.abs(pos.y - primaryDownAt.y) > 4)
        if moved or clicks >= 2 or event:getFlags().shift then
            local downAt = primaryDownAt
            hs.timer.doAfter(0.08, function() capturePrimary(downAt, pos) end)
        end
        return false
    end

    if event:getProperty(P.mouseEventButtonNumber) ~= 2 then return false end
    if t == MT.otherMouseUp then
        if primarySwallowUp then primarySwallowUp = false; return true end
        return false
    end

    -- boton central pulsado
    if not primaryText then plog("clic central: no hay nada seleccionado todavia"); return false end
    local pos = hs.mouse.absolutePosition()
    local editable, app, why = editableUnder(pos)
    plog("clic central: " .. (editable and "pega, " or "pasa de largo, ") .. why)
    if not editable then return false end
    primarySwallowUp = true
    local text = primaryText
    hs.timer.doAfter(0, function()
        hs.eventtap.leftClick(pos)
        hs.timer.doAfter(0.06, function()
            pastePreservingClipboard(text, app or hs.application.frontmostApplication())
        end)
    end)
    return true
end)

primaryTap:start()

dockScroll = {
    switch = pressSpaceShortcut,
    hint = showSwitchHint,
    hintState = function()
        return {
            canvases = hintCanvases and #hintCanvases or 0,
            running = hintTimer ~= nil,
        }
    end,
    moveWindow = moveFocusedWindowToSpace,
    moveScreen = moveWindowToScreen,
    overDock = mouseOverDock,
    zone = dockZone,
    primary = function() return primaryText end,
    primaryLog = function() return primaryLog end,
}

-- spaceswitch es imprescindible: mueve ventanas entre escritorios y es el respaldo si falta
-- noswoosh. cliclick ya no se usa en tiempo de ejecucion desde 2026-09-24.
if not hs.fs.attributes(SPACESWITCH) then
    hs.alert.show("Falta helper/spaceswitch: ejecuta bin/apply.sh del repo")
else
    hs.alert.show("Hammerspoon: scroll sobre el Dock cambia de escritorio")
end
