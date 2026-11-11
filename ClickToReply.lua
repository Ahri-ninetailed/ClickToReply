-- ClickToReply: ЛКМ по тексту сообщения игрока -> поле ввода в исходном канале с "Имя, ".
--
-- Аддон ничего не подменяет в чате: нет фильтров сообщений, нет перехвата AddMessage,
-- нет переопределения глобальных функций. Он только слушает глобальные события мыши,
-- читает данные, которые клиент сам сохранил вместе со строкой чата, и открывает поле
-- ввода штатным ChatFrameUtil.OpenChat (так же, как это делают ссылки на каналы).
--
-- ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ (не забыть!): клик по иконкам и пометкам, которые другие аддоны
-- дописывают ПЕРЕД текстом, отличается от клика по тексту только в одном случае: когда они
-- стоят на отдельной визуальной строке (например, при TwoLineChat: заголовок и иконки на первой
-- строке, текст на второй). Тогда см. IndexBelongsToLine.
-- Если иконки стоят в середине ТОЙ ЖЕ строки, что и текст (одна строка, без TwoLineChat), клиент
-- отдаёт позицию без учёта ширины иконок, и клик по иконке может сработать как клик по тексту.
-- Это в игре не проверялось и индексом символа не лечится. Лечить можно только сравнением клика
-- с положением текста в пикселях (измерять ширину "заголовок + иконки" вспомогательным
-- FontString): это уже архитектурное изменение, делать его только по согласованию с автором.

local issecretvalue = issecretvalue or function() return false end

-- Событие чата -> тип чата для ответа. Чего нет в таблице (шёпот, системные
-- сообщения, эмоции, лут, опыт и т.д.), аддон не трогает.
local REPLY_TYPE = {
    CHAT_MSG_SAY                  = "SAY",
    CHAT_MSG_YELL                 = "YELL",
    CHAT_MSG_CHANNEL              = "CHANNEL",
    CHAT_MSG_GUILD                = "GUILD",
    CHAT_MSG_OFFICER              = "OFFICER",
    CHAT_MSG_PARTY                = "PARTY",
    CHAT_MSG_PARTY_LEADER         = "PARTY",
    CHAT_MSG_RAID                 = "RAID",
    CHAT_MSG_RAID_LEADER          = "RAID",
    CHAT_MSG_RAID_WARNING         = "RAID",
    CHAT_MSG_INSTANCE_CHAT        = "INSTANCE_CHAT",
    CHAT_MSG_INSTANCE_CHAT_LEADER = "INSTANCE_CHAT",
}

-- Порядок значений, которые ChatFrameMixin:MessageEventHandler передаёт в AddMessage
-- после цвета: id типа, accessID, typeID, event, eventArgs, MessageFormatter.
-- Если порядок когда-нибудь изменится, проверки типов ниже просто отключат аддон.
local EXTRA_EVENT, EXTRA_ARGS, EXTRA_FORMATTER = 4, 5, 6

-- Номера аргументов события CHAT_MSG_*.
local ARG_TEXT, ARG_AUTHOR, ARG_CHANNEL_INDEX, ARG_GUID = 1, 2, 8, 12

local MAX_MOVE_SQ = 5 * 5 -- пикселей: больше - это перетаскивание, а не клик

if not (ChatFrameUtil and ChatFrameUtil.OpenChat and ChatFrameUtil.GetActiveWindow
        and GetMouseFoci and C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and CHAT_FRAMES) then
    print("|cffff7f00ClickToReply:|r нужные API клиента не найдены, аддон не работает.")
    return
end

local downX, downY   -- позиция курсора при нажатии ЛКМ
local linkClicked    -- за время этого клика сработала гиперссылка (ник, предмет, канал...)

-- Любой клик по ссылке в чате проходит через SetItemRef. Хук только пометка, на
-- выполнение Blizzard-кода он не влияет.
hooksecurefunc("SetItemRef", function() linkClicked = true end)

-- Обращение, которое мы сами вставили в поле ввода. Пока пользователь ничего своего не написал,
-- новый клик заменяет его на новое. Одного совпадения текста с "Имя, " для этого мало (то же самое
-- мог набрать сам пользователь), поэтому помним, ЧТО именно мы вставили, В КАКОЕ поле и в какой
-- канал, и забываем это при любом вмешательстве пользователя.
local auto           -- { editBox, text, chatType, channelTarget } или nil
local watched = {}   -- поля ввода, на которые уже повешены сбросы

local function Forget(editBox)
    if auto and auto.editBox == editBox then auto = nil end
end

local function Watch(editBox)
    if watched[editBox] then return end
    watched[editBox] = true
    -- OnTextChanged вызывается и при программной установке текста (наш OpenChat, разбор "/p " самим
    -- клиентом), но тогда userInput == false. Сбрасываем только по вводу пользователя.
    editBox:HookScript("OnTextChanged", function(self, userInput)
        if userInput then Forget(self) end
    end)
    -- Поле закрыли (отправка, Esc): текст очищается, но на всякий случай забываем и так.
    -- Потерю фокуса НЕ отслеживаем: клик по другому сообщению в чате снимает фокус с поля, а
    -- клиент закрывает поле при потере фокуса, только если оно пустое
    -- (ChatFrameEditBoxMixin:ShouldDeactivateChatOnEditFocusLost). Значит, "Имя, " остаётся в поле,
    -- и если бы мы его здесь забыли, повторный клик по другому нику ничего бы не менял.
    -- Текст при потере фокуса не меняется, а свой ввод пользователя ловит OnTextChanged выше.
    editBox:HookScript("OnHide", Forget)
end

-- В поле лежит ровно то, что вставили мы, поле и канал те же, и пользователь ничего не трогал.
local function IsUntouchedAuto(editBox, typed)
    if not (auto and auto.editBox == editBox and auto.text == typed) then return false end
    if editBox:GetChatType() ~= auto.chatType then return false end -- канал сменили вручную
    return auto.chatType ~= "CHANNEL" or editBox:GetChannelTarget() == auto.channelTarget
end

-- Последнее вхождение подстроки (без шаблонов).
local function FindLast(text, needle)
    local first, last, init = nil, nil, 1
    while true do
        local s, e = string.find(text, needle, init, true)
        if not s then break end
        first, last, init = s, e, s + 1
    end
    return first, last
end

-- Ищет в строке исходный текст сообщения (последнее вхождение, не раньше конца заголовка).
local function FindOriginal(message, first, original)
    if type(original) ~= "string" or original == "" or issecretvalue(original) then return end
    local s, e = FindLast(message, original)
    if s and s >= first then return s, e end
end

-- Если исходный текст в строке не нашёлся, пропускаем иконки (|A..|a, |T..|t), которые
-- аддоны ставят сразу после заголовка, и пробелы или переводы строки после них.
local function SkipLeadingTextures(message, pos)
    while true do
        pos = string.find(message, "%S", pos) or (#message + 1)
        local mark = string.sub(message, pos, pos + 1)
        local close = (mark == "|A" and "|a") or (mark == "|T" and "|t")
        if not close then return pos end
        local _, e = string.find(message, close, pos + 2, true)
        if not e then return pos end
        pos = e + 1
    end
end

-- Диапазон байтов строки, который считается "текстом сообщения".
-- Начало: сразу после заголовка. Заголовок (время, канал, ник) клиент строит сам, и
-- у каждой строки чата есть его форматтер, поэтому заголовок получаем у клиента, а не
-- разбираем регулярными выражениями. Если чужой заголовок не совпал с строкой побайтно
-- (кто-то переписал строку целиком), возвращаем nil и ничего не делаем.
-- Уточнение: если аддоны дописали что-то перед текстом (иконки, пометки), текст -
-- это исходная строка события (она хранится в eventArgs), её ищем в конце строки.
-- Если её там нет (текст кто-то переписал), пропускаем только иконки в начале.
local function BodyRange(message, formatter, original)
    if type(formatter) ~= "function" then return end
    local ok, header = pcall(formatter, "")
    if not ok or type(header) ~= "string" or issecretvalue(header) or header == "" then return end
    if string.sub(message, 1, #header) ~= header then return end

    local first, last = #header + 1, #message
    local s, e = FindOriginal(message, first, original)
    if s then return s, e end
    return SkipLeadingTextures(message, first), last
end

-- Можно ли сейчас писать в этот канал (те же условия, по которым Blizzard сбрасывает
-- поле ввода в "Сказать"). Иначе молча ничего не делаем, а не подставляем чужой канал.
local function CanWriteTo(chatType)
    if chatType == "PARTY" then
        return IsInGroup(LE_PARTY_CATEGORY_HOME)
    elseif chatType == "RAID" then
        return IsInRaid(LE_PARTY_CATEGORY_HOME)
    elseif chatType == "INSTANCE_CHAT" then
        return IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    elseif chatType == "GUILD" or chatType == "OFFICER" then
        return IsInGuild()
    end
    return true
end

-- Окно чата под курсором, если клик дошёл именно до чата, а не до другого окна.
local function ChatFrameUnderCursor()
    for _, name in ipairs(CHAT_FRAMES) do
        local chatFrame = _G[name]
        if chatFrame and chatFrame:IsVisible() and chatFrame:IsMouseOver() then
            for _, focus in ipairs(GetMouseFoci()) do
                if focus ~= WorldFrame and focus ~= chatFrame and focus ~= chatFrame.FontStringContainer then
                    return nil -- сверху другое окно, полоса прокрутки или кнопка
                end
            end
            return chatFrame
        end
    end
end

local function IsNumber(value)
    return type(value) == "number" and not issecretvalue(value)
end

-- Клиент выбирает визуальную строку по y, а для x за пределами её текста (например, над иконками
-- в конце строки) отдаёт индекс символа из СЛЕДУЮЩЕЙ строки. Поэтому индекс принимаем, только если
-- он лежит между первым символом строки под курсором и первым символом следующей строки.
-- Первые символы строк узнаём у самого клиента: тот же y у левого края и на строку ниже.
-- Не помогает, если иконки и текст на одной строке (см. "ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ" в начале файла).
local function IndexBelongsToLine(line, index, y)
    local left, height, count = line:GetLeft(), line:GetStringHeight(), line:GetNumLines()
    if not (IsNumber(left) and IsNumber(height) and IsNumber(count) and count > 0) then return false end
    local lineStart = line:FindCharacterIndexAtCoordinate(left + 1, y)
    if not IsNumber(lineStart) or index < lineStart then return false end
    local nextStart, nextInside = line:FindCharacterIndexAtCoordinate(left + 1, y - height / count)
    if nextInside and (not IsNumber(nextStart) or index >= nextStart) then return false end
    return true
end

-- Строка чата под курсором и индекс символа в её тексте (как в выделении текста Blizzard).
local function LineUnderCursor(chatFrame)
    local lines = chatFrame.visibleLines
    if type(lines) ~= "table" then return end
    local x, y = GetCursorPosition()
    local scale = chatFrame:GetEffectiveScale()
    x, y = x / scale, y / scale
    for _, line in ipairs(lines) do
        if line:IsShown() and line.messageInfo then
            local index, inside = line:FindCharacterIndexAtCoordinate(x, y)
            if index and inside then
                if IndexBelongsToLine(line, index, y) then return line, index end
                return
            end
        end
    end
end

-- Возвращает текст для поля ввода ("/g Имя, ") или nil, если по этому месту отвечать не нужно.
local function BuildReply(line, index)
    local info = line.messageInfo
    local extra = info and info.extraData
    if type(extra) ~= "table" then return end

    local chatType = type(extra[EXTRA_EVENT]) == "string" and REPLY_TYPE[extra[EXTRA_EVENT]]
    local args = extra[EXTRA_ARGS]
    local message = info.message
    if not chatType or type(args) ~= "table" or type(message) ~= "string" or issecretvalue(message) then return end

    local author, guid, channelIndex = args[ARG_AUTHOR], args[ARG_GUID], args[ARG_CHANNEL_INDEX]
    if issecretvalue(author) or issecretvalue(guid) or issecretvalue(channelIndex) then return end
    if type(author) ~= "string" or author == "" then return end

    local name = Ambiguate(author, "none")
    if (guid and guid == UnitGUID("player")) or name == UnitName("player") then return end -- свои сообщения

    local first, last = BodyRange(message, extra[EXTRA_FORMATTER], args[ARG_TEXT])
    if not first or index < first or index > last then return end -- время, канал, ник, пустое место

    if not CanWriteTo(chatType) then return end

    local slash
    if chatType == "CHANNEL" then
        if type(channelIndex) ~= "number" or channelIndex <= 0 or GetChannelName(channelIndex) == 0 then return end
        slash = "/" .. channelIndex
    else
        slash = _G["SLASH_" .. chatType .. "1"]
    end
    if type(slash) ~= "string" then return end

    return slash .. " " .. name .. ", ", name .. ", ", chatType, channelIndex
end

local function OnLeftMouseUp()
    local startX, startY = downX, downY
    downX, downY = nil, nil
    if not startX then return end

    local x, y = GetCursorPosition()
    if (x - startX) ^ 2 + (y - startY) ^ 2 > MAX_MOVE_SQ then return end
    if IsShiftKeyDown() or IsControlKeyDown() or IsAltKeyDown() then return end
    if C_ChatInfo.InChatMessagingLockdown() then return end

    local chatFrame = ChatFrameUnderCursor()
    if not chatFrame then return end
    local line, index = LineUnderCursor(chatFrame)
    if not line then return end
    local command, reply, chatType, channelIndex = BuildReply(line, index)
    if not command then return end

    -- Ссылка могла сработать до или после этого события, поэтому решаем на следующем кадре.
    C_Timer.After(0, function()
        if linkClicked then return end
        local editBox = ChatFrameUtil.GetActiveWindow()
        local typed = editBox and editBox:GetText()
        -- Есть хотя бы один непробельный символ: не трогаем ни текст, ни канал, ни курсор, ни фокус.
        -- Пустое поле или одни пробелы считаются пустыми, их заменит "Ник, ".
        -- Исключение: наше собственное нетронутое обращение, его заменяем на новое.
        if typed and string.find(typed, "%S") and not IsUntouchedAuto(editBox, typed) then return end
        local opened = ChatFrameUtil.OpenChat(command, chatFrame, #reply)
        auto = nil
        if opened and opened.HookScript then
            Watch(opened)
            auto = { editBox = opened, text = reply, chatType = chatType, channelTarget = channelIndex }
        end
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("GLOBAL_MOUSE_DOWN")
frame:RegisterEvent("GLOBAL_MOUSE_UP")
frame:SetScript("OnEvent", function(_, event, button)
    if button ~= "LeftButton" then return end
    if event == "GLOBAL_MOUSE_DOWN" then
        downX, downY = GetCursorPosition()
        linkClicked = false
    else
        OnLeftMouseUp()
    end
end)
