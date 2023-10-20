-- A script by @wqferr
-- configs a little bit farther down

-- CONTROLS THAT DIDNT FIT IN THE HELP SCREEN

-- running todolist with an argument will create a todo list file
-- with that name. you can use this to organize and have multiple
-- independent lists.
-- ctrl + C (hold) or ctrl + Q (press) to quit without saving
-- saves happen automatically after inactivity period (default 120)
-- ctrl + S to save immediately
-- quitting with just Q saves before exiting


-- CONFIGS --

-- in seconds, how long the process waits for it to
-- be considered inactive and autosave
local inactiveTimerLength = 120

-- in seconds, how long the process sleeps after drawing
-- lower values will increase responsiveness (down to 0.05),
-- while higher values will save on processing power and
-- energy consumption
local drawSleepCycleLen = 0.05

local selectedColorFG = 0xFFFFFF
local selectedColorBG = 0x000000

local unselectedColorFG = 0xAAAADD
local unselectedColorBG = 0x000000

local doneColorFG = 0x408040
local doneColorBG = 0x000000

local uiColorFG = 0xFFFFFF
local uiColorBG = 0x000000

local header = "To Do"

-- END OF CONFIGS

local component = require "component"
local event = require "event"
local keyboard = require "keyboard"
local term = require "term"
local fs = require "filesystem"
local shell = require "shell"
local computer = require "computer"

local gpu = component.gpu
local screenW, screenH = gpu.getResolution()

local args = {...}

local todoList = {}
local modified = false
local selectedIndex = nil
local selectedSubitem = 0 -- 0 if selecting a main item
local footerMsg = ""
local inactiveTimer = nil
local touchY -- y position of user touch
local mouseScrollDelta = 0
local mouseScrolling = false

-- linewise screen buffer
local screenBuffer = {}

local function redrawBufferLine(y)
  local line = screenBuffer[y]
  gpu.setForeground(line.fg)
  gpu.setBackground(line.bg)
  gpu.set(1, y, line.text)
end

local function resetBuffer()
  for i = 1, screenH do
    screenBuffer[i] = {
      text = "",
      fg = uiColorFG,
      bg = uiColorBG
    }
  end
end
resetBuffer()

local function clearScreen()
  term.clear()
  resetBuffer()
end

local function forceBufferRedraw()
  for y = 1, screenH do
    redrawBufferLine(y)
  end
end

local function setLine(x, y, text, fg, bg)
  fg = fg or gpu.getForeground()
  bg = bg or gpu.getBackground()
  local lPadding = (" "):rep(x-1)
  local rPadding = (" "):rep(screenW - x - #text)
  text = ("%s%s%s"):format(lPadding, text, rPadding):sub(1, screenW)
  local bufferLine = screenBuffer[y]
  if bufferLine.text ~= text or bufferLine.fg ~= fg or bufferLine.bg ~= bg then
    bufferLine.text = text
    bufferLine.fg = fg
    bufferLine.bg = bg
    redrawBufferLine(y)
  end
end

local function clearLine(y)
  setLine(1, y, "")
end

local function buildLine(...)
  local targs = {...}
  local line = (" "):rep(screenW)
  for i = 1, #targs, 2 do
    local x = targs[i]
    local text = targs[i+1]
    if not text then
      break
    end
    -- maximum length a string starting at X can have and not be cut off
    text = text:sub(1, screenW - x)
    line = line:sub(1, x - 1)..text..line:sub(x + #text + 1)
  end
  return line
end

local function addItem(text, done)
  local item = {
    text = text,
    done = done or false,
    subitems = {},
    collapsed = false
  }
  todoList[#todoList + 1] = item
  selectedIndex = #todoList
  selectedSubitem = 0
  return item
end

local function addSubItem(parent, text, done)
  local subitem = {
    text = text,
    done = done or false
  }
  parent.subitems[#parent.subitems + 1] = subitem
  selectedSubitem = #parent.subitems
end

local function toggleSelectedItem()
  if not selectedIndex then
    return
  end
  local item = todoList[selectedIndex]

  if selectedSubitem == 0 then
    -- main item
    item.done = not item.done
  else
    -- subitem
    local subitem = item.subitems[selectedSubitem]
    subitem.done = not subitem.done
  end
  modified = true
end

local function moveSelectedItemUp()
  if not selectedIndex then
    return
  end
  if selectedSubitem == 0 then
    if selectedIndex == 1 then
      return
    end
    local item = table.remove(todoList, selectedIndex)
    selectedIndex = selectedIndex - 1
    table.insert(todoList, selectedIndex, item)
  else
    if selectedSubitem == 1 then
      return
    end
    local sublist = todoList[selectedIndex].subitems
    local subitem = table.remove(sublist, selectedSubitem)

    selectedSubitem = selectedSubitem - 1
    table.insert(sublist, selectedSubitem, subitem)
  end
  modified = true
end

local function moveSelectedItemDown()
  if not selectedIndex then
    return
  end
  if selectedSubitem == 0 then
    if selectedIndex == #todoList then
      return
    end
    local item = table.remove(todoList, selectedIndex)
    selectedIndex = selectedIndex + 1
    table.insert(todoList, selectedIndex, item)
  else
    local sublist = todoList[selectedIndex].subitems
    if selectedSubitem == #sublist then
      return
    end
    local subitem = table.remove(sublist, selectedSubitem)
    selectedSubitem = selectedSubitem + 1
    table.insert(sublist, selectedSubitem, subitem)
  end
  modified = true
end

local function removeSelectedItem()
  if not selectedIndex then
    return
  end
  if selectedSubitem == 0 then
    table.remove(todoList, selectedIndex)
    if selectedIndex > #todoList then
      selectedIndex = #todoList
    end
  else
    local sublist = todoList[selectedIndex].subitems
    table.remove(sublist, selectedSubitem)
    if selectedSubitem > #sublist then
      selectedSubitem = #sublist
    end
  end
  modified = true
end

local function selectUp(mainItemsOnly)
  if #todoList == 0 then
    selectedIndex = nil
    selectedSubitem = 0
    return false
  end
  if not selectedIndex then
    selectedIndex = 1
    selectedSubitem = 0
    return true
  end

  if selectedSubitem > 0 then
    if mainItemsOnly then
      selectedSubitem = 0
    else
      selectedSubitem = selectedSubitem - 1
    end
    return true
  end

  if selectedIndex > 1 then
    selectedIndex = selectedIndex - 1
    if mainItemsOnly or todoList[selectedIndex].collapsed then
      selectedSubitem = 0
    else
      selectedSubitem = #todoList[selectedIndex].subitems
    end
    return true
  end

  return false
end

local function selectDown(mainItemsOnly)
  if #todoList == 0 then
    selectedIndex = nil
    selectedSubitem = 0
    return false
  end
  if not selectedIndex then
    selectedIndex = 1
    selectedSubitem = 0
    return true
  end

  local item = todoList[selectedIndex]
  local sublist = item.subitems
  if not item.collapsed and not mainItemsOnly and selectedSubitem < #sublist then
    selectedSubitem = selectedSubitem + 1
    return true
  end

  if selectedIndex < #todoList then
    selectedIndex = selectedIndex + 1
    selectedSubitem = 0
    return true
  end

  return false
end

local function realPath(filename)
  if filename:sub(1, 1) == "/" then
    return filename
  else
    return shell.getWorkingDirectory().."/"..filename
  end
end

local filename = args[1] or "/etc/todo/main.todo"
filename = realPath(filename)
local function makeDirStructureToFilename()
  if fs.exists(filename) then
    if fs.isDirectory(filename) then
      error("path " .. filename .. " is a directory")
    end
    return
  end
  local cumulativePath = ""
  local previousOneWasntDir = false
  for dir in filename:gmatch "[^/\\\\]+" do
    if previousOneWasntDir then
      error("path " .. cumulativePath .. " is not a directory")
    end
    cumulativePath = cumulativePath .. "/" .. dir
    if fs.exists(cumulativePath) then
      if not fs.isDirectory(cumulativePath) then
        previousOneWasntDir = true
      end
    else
      fs.makeDirectory(cumulativePath)
    end
  end
  if fs.isDirectory(filename) then
    fs.remove(filename)
  end
  local handle = fs.open(filename, "a")
  if handle then
    handle:close()
  end
end
makeDirStructureToFilename()

local saveMarkers = {
  [true] = "x", -- done
  [false] = " " -- not done
}
local function save()
  if not modified then
    return
  end
  local handle = fs.open(filename, "w")
  if not handle then
    error("Could not open file "..filename.." for saving")
  end
  for _, item in ipairs(todoList) do
    handle:write(saveMarkers[item.done])
    handle:write(item.text)
    handle:write "\n"
    for _, subitem in ipairs(item.subitems) do
      handle:write "s"
      handle:write(saveMarkers[subitem.done])
      handle:write(subitem.text)
      handle:write "\n"
    end
  end
  handle:close()
  modified = false
end

local function load()
  local handle = fs.open(filename, "r")
  if not handle then
    return
  end

  local contents = handle:read(math.huge)
  local parent = nil
  for line in (contents or ""):gmatch "[^\n]+" do
    local isSubitem = line:sub(1, 1) == "s"
    if isSubitem then
      local done = line:sub(2, 2) == saveMarkers[true]
      local text = line:sub(3)
      if not parent then
        local errMsg = 'Subitem cannot be first line in file: %q. Delete the first line or remove its leading S and try again.'
        error(errMsg)
      end
      addSubItem(parent, text, done)
    else
      local done = line:sub(1, 1) == saveMarkers[true]
      local text = line:sub(2)
      parent = addItem(text, done)
    end
  end
  handle:close()
end

local function suspendInactiveTimer()
  if inactiveTimer then
    event.cancel(inactiveTimer)
    inactiveTimer = nil
  end
end

local function resetInactiveTimer()
  suspendInactiveTimer()
  inactiveTimer = event.timer(inactiveTimerLength, save)
end

local Modes = {
  view = "View",
  create = "New",
  edit = "Edit",
  createSubitem = "New Subitem",
  delete = "Delete",
  purge = "Purge",
  move = "Move",
  help = "Help"
}

setmetatable(
  Modes,
  {
    __index = function(key)
      error("invalid mode: "..tostring(key))
    end
  }
)

local mode = Modes.view

local firstIndex = 1  -- scroll
local lastListLine = screenH - 1


local headerX = (screenW - #header) / 2
local function drawHeader()
  local headerY = 1
  setLine(headerX, headerY, header)
end

local function drawFooter()
  local footerX = screenW - #mode
  local footerY = screenH
  local padding = (" "):rep(screenW - #footerMsg - #mode - 1)
  local fullFooter = ("%s%s%s"):format(footerMsg, padding, mode)
  setLine(1, footerY, fullFooter)
end

local markers = {
  [true] = {  -- done
    [true] = "<x>",  -- selected
    [false] = "[x]"  -- not selected
  },
  [false] = {  -- not done
    [true] = "< >",  -- selected
    [false] = "[ ]"  -- not selected
  }
}

-- length of marker + space
-- TODO infer these limits by screen width and prefix/indent
local mainItemCharsPerLine = screenW - 4
local subitemIndent = 4
local subitemCharsPerLine = mainItemCharsPerLine - subitemIndent
-- returns number of lines printed and whether or not the whole string was printed
local function printBreakingAtSpaces(y, text, prefix, lineLength, indent, maxDrawY)
  local remainingStr = text
  local nLines = 0
  local indentStr = (" "):rep(indent or 0)
  repeat
    local lineStr = remainingStr:sub(1, lineLength)
    if #lineStr >= lineLength and remainingStr:sub(lineLength+1, lineLength+1) ~= " " then
      -- proper line breaks on whitespace
      local clipStart, clipEnd = lineStr:find ".*%s"
      if clipStart then
        lineStr = lineStr:sub(clipStart, clipEnd)
      end
      -- if not, just break wherever it ends
    end
    local line = ("%s%s %s"):format(indentStr, prefix, lineStr)
    setLine(1, y + nLines, line)
    remainingStr = remainingStr:sub(#lineStr + 1)
    nLines = nLines + 1
    prefix = (" "):rep(#prefix)
  until remainingStr == "" or y+nLines > maxDrawY
  return nLines, remainingStr == ""
end

local function detectTouch(itemIndex, subitemIndex)
  subitemIndex = subitemIndex or 0
  if selectedIndex == itemIndex and selectedSubitem == subitemIndex then
    toggleSelectedItem()
  else
    selectedIndex = itemIndex
    selectedSubitem = subitemIndex
  end
  touchY = nil
end

local function setColors(fg, bg)
  if gpu.getDepth() == 1 then
    return
  end
  gpu.setForeground(fg)
  gpu.setBackground(bg)
end

local maxItemDrawY = screenH - 1
local function drawSubitems(item, index, drawY)
  local firstUnshownSubitem = 0
  local totalLines = 0
  local lastDrawnSubitemFullyVisible = true
  if item.collapsed and #item.subitems > 0 then
    setColors(unselectedColorFG, unselectedColorBG)
    if drawY <= maxItemDrawY then
      lastDrawnSubitemFullyVisible = true
      setLine(1, drawY, (" "):rep(subitemIndent).."[...]")
    else
      lastDrawnSubitemFullyVisible = false
    end
    return 1, #item.subitems, lastDrawnSubitemFullyVisible
  end
  for i, subitem in ipairs(item.subitems) do
    if drawY >= screenH then
      break
    end
    firstUnshownSubitem = i
    local selected = index == selectedIndex and selectedSubitem == i
    local marker = markers[subitem.done][selected]
    if subitem.done then
      setColors(doneColorFG, doneColorBG)
    elseif selected then
      setColors(selectedColorFG, selectedColorBG)
    else
      setColors(unselectedColorFG, unselectedColorBG)
    end
    local subitemHeight, subitemDisplayedFully = printBreakingAtSpaces(
      drawY, subitem.text, marker, subitemCharsPerLine, subitemIndent, maxItemDrawY
    )
    lastDrawnSubitemFullyVisible = subitemDisplayedFully
    local nextDrawY = drawY + subitemHeight
    if touchY and touchY >= drawY and touchY < nextDrawY then
      detectTouch(index, i)
    end
    drawY = nextDrawY
    totalLines = totalLines + subitemHeight
  end
  firstUnshownSubitem = firstUnshownSubitem + 1
  return totalLines, firstUnshownSubitem, lastDrawnSubitemFullyVisible
end

local function drawItem(item, index, drawY)
  local selected = index == selectedIndex and selectedSubitem == 0
  local marker = markers[item.done][selected]
  if item.done then
    setColors(doneColorFG, doneColorBG)
  elseif selected then
    setColors(selectedColorFG, selectedColorBG)
  else
    setColors(unselectedColorFG, unselectedColorBG)
  end
  local totalLines = 0
  local mainItemHeight, itemDisplayedFully = printBreakingAtSpaces(drawY, item.text, marker, mainItemCharsPerLine, 0, maxItemDrawY)
  local nextDrawY = drawY + mainItemHeight
  totalLines = totalLines +  mainItemHeight
  if touchY and touchY >= drawY and touchY < nextDrawY then
    detectTouch(index)
  end
  drawY = nextDrawY

  local subitemLines, firstUnshownSubitem, lastShownSubitemInFull = drawSubitems(item, index, drawY)
  totalLines = totalLines + subitemLines

  return totalLines, firstUnshownSubitem, itemDisplayedFully, lastShownSubitemInFull
end

local helpLeftColStart = math.floor(screenW/2) - 20
local helpRightColStart = helpLeftColStart + 20
local function buildHelpLine(left, right)
  return buildLine(helpLeftColStart, left, helpRightColStart, right)
end
local function drawHelp()
  setColors(uiColorFG, uiColorBG)
  local line = buildHelpLine("up, down, j, k", "move cursor")
  setLine(1, 3, line)

  line = buildHelpLine("ctrl + up, down", "previous, next main item")
  setLine(1, 4, line)

  line = buildHelpLine("space, x, enter", "toggle done")
  setLine(1, 5, line)

  line = buildHelpLine("a, c, n", "new item")
  setLine(1, 6, line)

  line = buildHelpLine("s", "new subitem")
  setLine(1, 7, line)

  line = buildHelpLine("delete, d", "remove item")
  setLine(1, 8, line)

  line = buildHelpLine("m", "toggle move mode")
  setLine(1, 9, line)

  line = buildHelpLine("e", "edit item")
  setLine(1, 10, line)

  line = buildHelpLine("+, -", "collapse, uncollapse")
  setLine(1, 11, line)

  line = buildHelpLine("p", "purge all done")
  setLine(1, 12, line)

  if screenH > 16 then
    setLine(helpLeftColStart, 14, "current mode is displayed on the")
    setLine(helpLeftColStart, 15, "bottom right corner of the screen")
  end

  line = buildHelpLine("h", "open help")
  setLine(1, screenH - 3, line)

  line = buildHelpLine("q", "quit")
  setLine(1, screenH - 2, line)
end

local keyDownHandler, interruptedHandler, touchHandler, scrollHandler
local shouldExit = false

local function quit()
  term.clear()
  shouldExit = true

  -- unregister event listeners
  suspendInactiveTimer()
  event.ignore("key_down", keyDownHandler)
  event.ignore("interrupted", interruptedHandler)
  event.ignore("touch", touchHandler)
  event.ignore("scroll", scrollHandler)
end

function touchHandler(_, _, _, y)
  resetInactiveTimer()
  touchY = y
  mouseScrolling = false
end

local function purgeAllDone()
  term.setCursor(1, 1)
  selectedIndex = #todoList
  while selectedIndex >= 1 do
    local item = todoList[selectedIndex]
    selectedSubitem = #item.subitems
    while selectedSubitem >= 1 do
      if item.subitems[selectedSubitem].done then
        table.remove(item.subitems, selectedSubitem)
      end
      selectedSubitem = selectedSubitem - 1
    end
    if item.done and #item.subitems == 0 then
      table.remove(todoList, selectedIndex)
    end
    selectedIndex = selectedIndex - 1
  end

  if #todoList > 0 then
    selectedIndex = 1
  else
    selectedIndex = nil
  end
  selectedSubitem = 0
end

local toggleKeys = {
  [keyboard.keys.x] = true,
  [keyboard.keys.space] = true,
  [keyboard.keys.enter] = true
}
local upKeys = {
  [keyboard.keys.up] = true,
  [keyboard.keys.k] = true
}
local downKeys = {
  [keyboard.keys.down] = true,
  [keyboard.keys.j] = true
}
local exitKeys = {
  [keyboard.keys.q] = true
}
local createKeys = {
  [keyboard.keys.a] = true,
  [keyboard.keys.c] = true,
  [keyboard.keys.n] = true
}
local createSubitemKeys = {
  [keyboard.keys.s] = true
}
local deleteKeys = {
  [keyboard.keys.delete] = true,
  [keyboard.keys.d] = true
}
local confirmKeys = {
  [keyboard.keys.y] = true,
  [keyboard.keys.enter] = true
}
local cancelKeys = {
  [keyboard.keys.n] = true,
  [keyboard.keys.q] = true
}
local moveExitKeys = {
  [keyboard.keys.q] = true,
  [keyboard.keys.m] = true,
  [keyboard.keys.enter] = true
}
local collapseKeys = {
  [keyboard.keys.minus] = true,
  [keyboard.keys.left] = true
}
local uncollapseKeys = {
  [keyboard.keys.equals] = true,
  [keyboard.keys.right] = true
}
local editKeys = {
  [keyboard.keys.e] = true
}
local purgeKeys = {
  [keyboard.keys.p] = true
}
-- declared as local above
function keyDownHandler(_, _, _, keyCode)
  mouseScrolling = false
  keyCode = math.floor(keyCode)
  if keyboard.isControlDown() then
    if upKeys[keyCode] then
      selectUp(true)
    elseif downKeys[keyCode] then
      selectDown(true)
    elseif keyCode == keyboard.keys.s then
      save()
    elseif keyCode == keyboard.keys.q then
      quit()
    end
  end
  if keyboard.isControlDown() or keyboard.isAltDown() or keyboard.isShiftDown() then
    return
  end
  if mode == Modes.view then
    if upKeys[keyCode] then
      resetInactiveTimer()
      selectUp()
    elseif downKeys[keyCode] then
      resetInactiveTimer()
      selectDown()
    elseif keyCode == keyboard.keys.home then
      if #todoList > 0 then
        selectedIndex = 1
        selectedSubitem = 0
      end
    elseif keyCode == keyboard.keys["end"] then
      if #todoList > 0 then
        selectedIndex = #todoList
        selectedSubitem = #todoList[selectedIndex].subitems
      end
    elseif toggleKeys[keyCode] then
      resetInactiveTimer()
      toggleSelectedItem()
    elseif exitKeys[keyCode] then
      save()
      quit()
    elseif createKeys[keyCode] then
      -- dont save until after item is created
      suspendInactiveTimer()
      clearScreen()
      mode = Modes.create
    elseif selectedIndex and createSubitemKeys[keyCode] then
      -- dont save until after subitem is created
      suspendInactiveTimer()
      clearScreen()
      mode = Modes.createSubitem
    elseif deleteKeys[keyCode] then
      if selectedIndex then
        suspendInactiveTimer()  -- dont save until after the user confirms deletion
        clearScreen()
        mode = Modes.delete
      end
    elseif keyCode == keyboard.keys.m then
      if selectedIndex then
        resetInactiveTimer()
        mode = Modes.move
      end
    elseif keyCode == keyboard.keys.h then
      -- it doesnt matter if there's lag in the help screen
      -- dont resetInactiveTimer()
      clearScreen()
      mode = Modes.help
    elseif collapseKeys[keyCode] then
      if selectedIndex then
        local item = todoList[selectedIndex]
        if selectedSubitem > 0 then
          selectedSubitem = 0
        end
        item.collapsed = true
      end
    elseif uncollapseKeys[keyCode] then
      if selectedIndex then
        local item = todoList[selectedIndex]
        if item.collapsed then
          item.collapsed = false
          selectedSubitem = 0
        end
      end
    elseif editKeys[keyCode] then
      suspendInactiveTimer()
      clearScreen()
      mode = Modes.edit
    elseif purgeKeys[keyCode] then
      suspendInactiveTimer()
      clearScreen()
      mode = Modes.purge
    end
  elseif mode == Modes.create or mode == Modes.createSubitem or mode == Modes.edit then
    -- NOP, term.read will take care of this
  elseif mode == Modes.delete then
    if confirmKeys[keyCode] then
      resetInactiveTimer()
      removeSelectedItem()
      clearScreen()
      mode = Modes.view
    elseif cancelKeys[keyCode] then
      clearScreen()
      mode = Modes.view
    end
  elseif mode == Modes.purge then
    if confirmKeys[keyCode] then
      resetInactiveTimer()
      purgeAllDone()
      clearScreen()
      mode = Modes.view
    elseif cancelKeys[keyCode] then
      clearScreen()
      mode = Modes.view
    end
  elseif mode == Modes.move then
    if upKeys[keyCode] then
      resetInactiveTimer()
      moveSelectedItemUp()
    elseif downKeys[keyCode] then
      resetInactiveTimer()
      moveSelectedItemDown()
    elseif moveExitKeys[keyCode] then
      resetInactiveTimer()
      mode = Modes.view
    end
  elseif mode == Modes.help then
    if keyCode == keyboard.keys.q then
      resetInactiveTimer()
      clearScreen()
      mode = Modes.view
    end
  end
end

local middleUpRow = math.floor((screenH+1) / 2)
local function draw()
  setColors(uiColorFG, uiColorBG)
  drawHeader()
  if mode == Modes.help then
    footerMsg = "Press Q to return"
  elseif mode == Modes.view then
    footerMsg = "Press H for help"
  elseif mode == Modes.move then
    footerMsg = "Press M to confirm position"
  else
    footerMsg = ""
  end
  drawFooter()
  local firstUnshownSubitem = 0
  if mode == Modes.view or mode == Modes.move then
    local itemDrawY = 2
    local i = firstIndex
    local itemShownInFull, subitemShownInFull
    while i <= #todoList and itemDrawY <= lastListLine do
      local item = todoList[i]
      local itemHeight
      itemHeight, firstUnshownSubitem, itemShownInFull, subitemShownInFull = drawItem(item, i, itemDrawY)
      itemDrawY = itemDrawY + itemHeight
      i = i + 1
    end
    -- touch detection happens in drawItem, clear "flag"
    touchY = nil
    local firstUnshownItem = i
    if selectedIndex then
      if mouseScrolling then
        if mouseScrollDelta < 0
            or firstUnshownItem < #todoList
            or firstUnshownSubitem < #todoList[#todoList].subitems
            or not itemShownInFull or not subitemShownInFull then
          -- end of list is not being shown, scroll downwards freely
          -- always ok to scroll up
          firstIndex = firstIndex + mouseScrollDelta
          if firstIndex < 1 then
            firstIndex = 1
          elseif firstIndex > #todoList then
            firstIndex = #todoList
          end
        end
        mouseScrollDelta = 0
        -- firstIndex = firstIndex + mouseScrollDelta
        if selectedIndex < firstIndex  then
          -- select first visible item if previous selected item went off-screen
          selectedIndex = firstIndex
          selectedSubitem = 0
        elseif selectedIndex >= firstUnshownItem then
          -- select last visible item if previous selected item went off-screen
          selectedIndex = firstUnshownItem
          selectedSubitem = 0
          selectUp() -- handles collapsed items
        elseif selectedIndex == firstUnshownItem - 1 and selectedSubitem >= firstUnshownSubitem then
          -- selected index is last visible item and selected sub item just went off-screen
          selectedSubitem = firstUnshownSubitem - 1
        end
      else
        if selectedIndex < firstIndex then
          -- scroll up
          firstIndex = firstIndex - 1
        elseif selectedIndex >= firstUnshownItem then
          -- scroll down
          firstIndex = firstIndex + 1
        elseif selectedIndex > 1 and selectedIndex == firstUnshownItem - 1 then
          -- only if selectedIndex > 1 to avoid a loop in case a single item
          -- occupies the entire screen
          if selectedSubitem == 0 and not itemShownInFull then
            -- scroll down if last item not fully visible
            firstIndex = firstIndex + 1
          elseif selectedSubitem == firstUnshownSubitem - 1 and not subitemShownInFull then
            firstIndex = firstIndex + 1
          elseif todoList[selectedIndex].collapsed and not subitemShownInFull then
            firstIndex = firstIndex + 1
          end
        end
        if selectedIndex == firstUnshownItem-1 and selectedSubitem >= firstUnshownSubitem then
          -- scroll down if selected subitem is off-screen
          firstIndex = firstIndex + 1
        end
      end
    end
    -- clear remaining lines
    for y = itemDrawY, screenH - 1 do
      clearLine(y)
    end
    setColors(uiColorFG, uiColorBG)
  elseif mode == Modes.create then
    setLine(1, middleUpRow-1, "New item:")
    setLine(1, middleUpRow, "Leave blank to cancel")
    term.setCursor(1, middleUpRow+1)
    local newItem = term.read():sub(1, -2) -- sub to remove \n
    if newItem ~= "" then
      addItem(newItem)
      selectedIndex = #todoList
      modified = true
    end
    resetInactiveTimer()
    mode = Modes.view
  elseif mode == Modes.edit then
    setLine(1, middleUpRow-1, "New text for item:")
    setLine(1, middleUpRow, "Press up for original text, leave blank to cancel")
    term.setCursor(1, middleUpRow+1)
    local affectedItemOrSubitem
    if selectedSubitem == 0 then
      affectedItemOrSubitem = todoList[selectedIndex]
    else
      affectedItemOrSubitem = todoList[selectedIndex].subitems[selectedSubitem]
    end
    local history = {affectedItemOrSubitem.text}
    local newText = term.read(history):sub(1, -2)
    if newText ~= "" then
      affectedItemOrSubitem.text = newText
      modified = true
    end
    resetInactiveTimer()
    mode = Modes.view
  elseif mode == Modes.createSubitem then
    local item = todoList[selectedIndex]
    setLine(1, middleUpRow-1, ("New subitem for: %q"):format(item.text))
    setLine(1, middleUpRow, "Leave blank to cancel")
    term.setCursor(1, middleUpRow+1)
    local newSubitem = term.read():sub(1, -2) -- sub to remove \n
    if newSubitem ~= "" then
      addSubItem(item, newSubitem)
      selectedSubitem = #item.subitems
      modified = true
    end
    resetInactiveTimer()
    mode = Modes.view
  elseif mode == Modes.delete then
    if selectedSubitem == 0 then
      setLine(1, middleUpRow, "Delete following item? [Y/n]")
      term.setCursor(1, middleUpRow+1)
      term.write(todoList[selectedIndex].text, true)
    else
      setLine(1, middleUpRow-1, "Delete following sub item? [Y/n]")
      setLine(1, middleUpRow, todoList[selectedIndex].text)
      setLine(4, middleUpRow+1, todoList[selectedIndex].subitems[selectedSubitem].text)
    end
  elseif mode == Modes.purge then
    setLine(1, middleUpRow, "Purge all done items? [Y/n]")
  elseif mode == Modes.help then
    drawHelp()
  end
end

-- declared as local above
function scrollHandler(_, _, _, _, direction)
  resetInactiveTimer()
  if #todoList == 0 then
    return
  end
  -- positive is up, so we need to flip it
  mouseScrollDelta = -direction
  mouseScrolling = true
end

-- declared as local above
function interruptedHandler()
  quit()
end
event.listen("interrupted", interruptedHandler)
event.listen("key_down", keyDownHandler)
event.listen("touch", touchHandler)
event.listen("scroll", scrollHandler)

load()
if #todoList > 0 then
  selectedIndex = 1
  selectedSubitem = 0
end

while not shouldExit do
  draw()
  computer.pullSignal(drawSleepCycleLen)
end