-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCLoadedVehicles - one bounded server walk over the loaded vehicle Set.
--
-- Consumers keep their own policy: this owns only the Set snapshot and the
-- independent-vehicle failure result. getVehicles() returns the live HashSet
-- (IsoCell.java:193-194, 2379-2381), and BaseVehicle.removeFromWorld removes
-- from that Set (BaseVehicle.java:7176-7177). Close the Java iteration before
-- any consumer runs so a janitor/removal callback cannot invalidate it.

RCLoadedVehicles = RCLoadedVehicles or {}

function RCLoadedVehicles.each(fn)
    local result = { visited = 0, failed = 0 }
    local cell = getCell and getCell()
    if not cell then return result end
    local vehicles = cell:getVehicles()
    if not vehicles then return result end
    local it = vehicles:iterator()
    if not it then return result end

    local snapshot = {}
    while it:hasNext() do
        local vehicle = it:next()
        if vehicle then snapshot[#snapshot + 1] = vehicle end
    end

    for i = 1, #snapshot do
        result.visited = result.visited + 1
        -- A consumer may reconcile, classify, transmit, or remove one car.
        -- That is a non-rollbackable independent unit: record its fault and
        -- continue to the next vehicle, leaving caller policy outside this
        -- narrow boundary.
        local ok, err = pcall(fn, snapshot[i])
        if not ok then
            result.failed = result.failed + 1
            if not result.firstError then result.firstError = tostring(err) end
        end
    end
    return result
end

return RCLoadedVehicles
