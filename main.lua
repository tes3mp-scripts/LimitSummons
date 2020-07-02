local Summons = {}

Summons.scriptName = "LimitSummons"

Summons.defaultConfig = {
    limit = {
        enable = false,
        count = 2
    },
    penalty = {
        enable = true,
        skill = 10,
        name = "Conjuration sickness"
    }
}

Summons.config = Summons.defaultConfig--jsonConfig.Load(Summons.scriptName, Summons.defaultConfig)

Summons.penalty = {}
Summons.mapSummonPid = {}


function Summons.removeObject(uniqueIndex, cellDescription)
    LoadedCells[cellDescription]:DeleteObjectData(uniqueIndex)
    if next(Players) ~= nil then
        logicHandler.DeleteObjectForEveryone(cellDescription, uniqueIndex)
    end
end

function Summons.removeFromNewCell(uniqueIndex, cellDescription)
    local tempLoad = false
    if  LoadedCells[cellDescription] == nil then
        logicHandler.LoadCell(cellDescription)
        tempLoad = true
    end

    local newCellDescription = LoadedCells[cellDescription].data.packets.cellChangeTo[uniqueIndex]

    if newCellDescription ~= nil then
        if LoadedCells[newCellDescription] ~= nil then
            Summons.removeObject(uniqueIndex, newCellDescription)
        end
    end

    Summons.removeObject(uniqueIndex, cellDescription)

    if tempLoad then
        logicHandler.UnloadCell(cellDescription)
    end
end

function SummonsTimer(pid, uniqueIndex, cellDescription)
    Summons.removeFromNewCell(uniqueIndex, cellDescription)
    tes3mp.LogMessage(enumerations.log.INFO, string.format("Timer for %s by %d", uniqueIndex, pid))
    tes3mp.SendMessage(pid, string.format("Timer for %s \n", uniqueIndex))
    if Players[pid] ~= nil then
        Summons.updatePenalty(pid, Summons.countSummons(pid))
    end
    Summons.mapSummonPid[uniqueIndex] = nil
end

function Summons.countSummons(pid)
    local summons = Players[pid].summons
    if summons == nil then
        return 0
    end

    local i = 0
    for k in pairs(summons) do
        i = i + 1
    end

    return i
end

function Summons.createPenalty(pid)
    local recordStore = RecordStores["spell"]
    local id = recordStore:GenerateRecordId()
    Summons.penalty[pid] = id

    local recordTable = {
        name = Summons.config.penalty.name,
        subtype = 2,
        effects = {{
            id = 21,
            attribute = -1,
            skill = 13,
            rangeType = 0,
            area = 0,
            magnitudeMin = 0,
            magnitudeMax = 0
        }}
    }

    recordStore.data.generatedRecords[id] = recordTable

    recordStore:AddLinkToPlayer(id, Players[pid])
    Players[pid]:AddLinkToRecord("spell", id)
    recordStore:Save()
end

function Summons.sendSpell(pid, id, action)
    tes3mp.LogMessage(enumerations.log.INFO, string.format("Sending spell package %d %s %d", pid, id, action))
    tes3mp.ClearSpellbookChanges(pid)
    tes3mp.SetSpellbookChangesAction(pid, action)
    tes3mp.AddSpell(pid, id)
    tes3mp.SendSpellbookChanges(pid)
end

function Summons.applyPenalty(pid, readd)
    local recordStore = RecordStores["spell"]
    local id = Summons.penalty[pid]

    Summons.sendSpell(pid, id, enumerations.spellbook.REMOVE)

    if not tableHelper.containsValue(Players[pid].data.spellbook, id) then
        table.insert(Players[pid].data.spellbook, id)
    end

    if readd then
        tableHelper.removeValue(Players[pid].generatedRecordsReceived, id)
        recordStore:LoadGeneratedRecords(pid, recordStore.data.generatedRecords, {id})

        Summons.sendSpell(pid, id, enumerations.spellbook.ADD)
    end
end

function Summons.updatePenalty(pid, count)
    if Summons.penalty[pid] == nil then
        tes3mp.LogMessage(enumerations.log.INFO, "Creating penalty for "..pid)
        Summons.createPenalty(pid)
    end

    local recordStore = RecordStores["spell"]

    local magnitude = count * Summons.config.penalty.skill
    local id = Summons.penalty[pid]

    recordStore.data.generatedRecords[id].effects[1].magnitudeMin = magnitude
    recordStore.data.generatedRecords[id].effects[1].magnitudeMax = magnitude

    Summons.applyPenalty(pid, magnitude > 0)
end

function Summons.destroyPenalty(pid)
    local recordStore = RecordStores["spell"]
    local id = Summons.penalty[pid]
    
    Summons.penalty[pid] = nil

    if id ~= nil then
        recordStore.data.generatedRecords[id] = nil

        recordStore:RemoveLinkToPlayer(id, Players[pid])
        Players[pid]:RemoveLinkToRecord("spell", id)
        recordStore:Save()

        Summons.sendSpell(pid, id, enumerations.spellbook.REMOVE)
    end

    tableHelper.removeValue(Players[pid].data.spellbook, id)
    tableHelper.cleanNils(Players[pid].data.spellbook)
end



function Summons.OnObjectSpawn(eventStatus, pid, cellDescription, objects)
    if not eventStatus.validCustomHandlers then return end
    for uniqueIndex, object in pairs(objects) do
        if object.summon then
            if object.summon.duration > 0 then
                tes3mp.LogMessage(enumerations.log.INFO,
                string.format("Starting timer for %s after %d seconds", uniqueIndex, object.summon.duration))
                timers.Timeout(
                    function()
                        SummonsTimer(pid, uniqueIndex, cellDescription)
                    end,
                    time.seconds(object.summon.duration) + 100
                )

                if object.hasPlayerSummoner then
                    local summonerPid = object.summon.summonerPid
                    local count = Summons.countSummons(summonerPid)
                    if Summons.config.limit.enable
                        and count >= Summons.config.limit.count
                    then
                        Summons.removeFromNewCell(uniqueIndex, cellDescription)
                        return customEventHooks.makeEventStatus(false, false)
                    end
                    Summons.mapSummonPid[uniqueIndex] = summonerPid
                    count = count + 1
                    if Summons.config.penalty.enable then
                        Summons.updatePenalty(summonerPid, count)
                    end
                end
            end
        end
    end
end

customEventHooks.registerValidator("OnObjectSpawn", Summons.OnObjectSpawn)


function Summons.OnObjectDelete(eventStatus, pid)
    if not eventStatus.validCustomHandlers then return end
    tes3mp.ReadReceivedObjectList()

    for objectIndex = 0, tes3mp.GetObjectListSize() - 1 do
        local uniqueIndex = tes3mp.GetObjectRefNum(objectIndex) .. "-" .. tes3mp.GetObjectMpNum(objectIndex)
        local summonerPid = Summons.mapSummonPid[uniqueIndex]
        if summonerPid ~= nil then
            tes3mp.SendMessage(summonerPid, string.format("Despawned %s \n", uniqueIndex))
            tes3mp.LogMessage(enumerations.log.INFO, string.format("Summon %s by %d", uniqueIndex, summonerPid))
            Summons.updatePenalty(summonerPid, Summons.countSummons(summonerPid))
        end
    end
end

customEventHooks.registerValidator("OnObjectDelete", Summons.OnObjectDelete)


function Summons.OnPlayerDisconnect(eventStatus, pid)
    if not eventStatus.validCustomHandlers then return end
    Summons.destroyPenalty(pid)
end

customEventHooks.registerValidator("OnPlayerDisconnect", Summons.OnPlayerDisconnect)


function Summons.OnServerExit(eventStatus)
    if not eventStatus.validCustomHandlers then return end
    for pid, player in pairs(Players) do
        Summons.destroyPenalty(pid)
        for uniqueIndex, summon in pairs(Players[pid].summons) do
            local cell = logicHandler.GetCellContainingActor(uniqueIndex)
            Summons.removeFromNewCell(uniqueIndex, cell.description)
        end
    end
end

customEventHooks.registerHandler("OnServerExit", Summons.OnServerExit)


return Summons