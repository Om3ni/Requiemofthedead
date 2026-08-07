-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMFieldForm - a DFForm bound to one zone's registered fields.
--
-- Both halves of the editor need the same thing: take the field registry, take
-- the selected zone in the draft, and render one editable dial per field. The
-- Zone Selector's properties cell does it for LMCore's own vocabulary - the
-- policies that are true for a zone absent any other mod - and the Details view
-- does it once per registered mod. One binding, so the two panels cannot
-- disagree about what an override is or when a value is inherited.
--
-- WHY THE SCHEMA IS BUILT FROM THE REGISTRY AND NOT WRITTEN DOWN. A mod that
-- registers a field gets a control for it with no further work and no edit to
-- this file; that is the whole of the Details contract (§11.3). It also means
-- the panel can never list a dial the store does not understand, or miss one it
-- does.
--
-- INHERITANCE IS SHOWN, NOT HIDDEN. A dial displays what the zone RESOLVES to -
-- its own value if it has one, otherwise its parent's, otherwise the registry
-- default - and marks the ones the zone actually sets. Showing a blank for an
-- inherited value would have an admin type in a number that was already in
-- force, writing a redundant override into the store for nothing; showing the
-- inherited value without marking it would hide which zone owns the setting.
--
-- STRING FIELDS RENDER NOW (2026-08-06). DFForm grew two kinds and they landed
-- in Core, where every form in the family gets them, rather than being bolted
-- onto this panel:
--   choice - a pill cycling a closed set, storing the STRING (`zeds`)
--   text   - a box that opens DFEntry to type in (`title`, `subtitle`, `lewtkey`)
-- The distinction is whether anybody validates the value, not what its type is;
-- `zeds` is a string whose only two honoured words are "none" and "remove", so a
-- free text box there would let an admin type "Remove" and get silence.
--
-- skipped() therefore reports nothing today. It stays because the mechanism is
-- the point: a registrant can declare a `ui` this form has never heard of, and
-- counting those beats dropping them silently. `colour` is the next one.

if isServer() then return end

require "DFForm"
require "LMCore"
require "LMEdit"

LMFieldForm = LMFieldForm or {}

-- A number field with no declared range still needs a stepper range, and the
-- registry is allowed not to have one. These bound the CONTROL, never the value.
local WIDE_MIN, WIDE_MAX = -100000, 100000

-- Which DFForm control a spec deserves. `ui` from the registrant wins; otherwise
-- the type decides. Returns nil for a field this form cannot draw.
local KINDS = { bool = true, int = true, enum = true, choice = true, text = true }

local function kindOf(spec)
    -- A choice with nothing to choose from is a pill that cannot be clicked out
    -- of its current value. Fall back to text so the field stays editable, which
    -- is the failure a registrant would want over a dead control.
    if spec.ui == "choice" and #(spec.values or {}) == 0 then return "text" end
    if spec.ui and KINDS[spec.ui] then return spec.ui end
    if spec.ui then return nil end                 -- "colour": not yet
    if spec.type == "boolean" then return "bool" end
    if spec.type == "number"  then return "int"  end
    -- A string with no declared ui is prose by default. A registrant with a
    -- closed set has to say `ui = "choice"` and list it, because this file
    -- cannot tell "any sentence" from "one of three words" by looking at a type.
    if spec.type == "string"  then return "text" end
    return nil
end

-- opts:
--   owner      restrict to one registrant (nil = every field)
--   title      heading prefix for the ? popout
--   groups     true to emit a group header per owner (only useful when owner is nil)
--   zone()     current zone name, or nil
--   draft()    current LMEdit draft, or nil
--   onChange() called after any write, so the host can refresh its chrome
function LMFieldForm.new(opts)
    local schema, skipped = {}, {}
    local lastOwner, lastGroup = nil, nil

    for _, s in ipairs(Limes.fields.list(opts.owner)) do
        local kind = kindOf(s)
        if not kind then
            skipped[#skipped + 1] = s.name
        else
            if opts.groups and s.owner ~= lastOwner then
                local info = Limes.mods.info(s.owner)
                schema[#schema + 1] = { group = info and info.label or s.owner }
                lastOwner = s.owner
                lastGroup = nil          -- a new owner restarts the sections
            end
            -- SECTIONS COME FROM THE REGISTRY, not from this file. Seventeen
            -- dials in one flat column is a wall; the registrant is the only
            -- thing that knows Restrictions are not Loot, so it says so on the
            -- spec and the form obeys. Fields with no group simply run on
            -- without a header, which is what a short vocabulary wants.
            if s.group and s.group ~= lastGroup then
                schema[#schema + 1] = { group = s.group }
                lastGroup = s.group
            end
            local row = {
                key   = s.name,
                kind  = kind,
                label = s.label or s.name,
                help  = s.help,
                unit  = (s.unit ~= "" and s.unit) or nil,
                zero  = s.zero,
            }
            if kind == "int" then
                row.min  = s.min or WIDE_MIN
                row.max  = s.max or WIDE_MAX
                row.step = s.step or 1
            elseif kind == "enum" then
                row.values    = s.values or {}
                row.numValues = #(s.values or {})
            elseif kind == "choice" then
                row.values = s.values or {}
                row.labels = s.labels
            elseif kind == "text" then
                row.empty       = s.empty
                row.rule        = s.rule
                row.maxLen      = s.maxLen
                row.placeholder = s.placeholder
            end
            schema[#schema + 1] = row
        end
    end

    local form = DFForm.new{
        schema = schema,
        title  = opts.title or "Zone",
        -- The RESOLVED value, from the draft rather than the live store: editing
        -- a parent has to move its children before anything is saved.
        get = function(key)
            local d, z = opts.draft(), opts.zone()
            if not (d and z) then return nil end
            return (d:effective(z, key))
        end,
        set = function(key, value)
            local d, z = opts.draft(), opts.zone()
            if not (d and z) then return end
            d:setField(z, key, value)
            if opts.onChange then opts.onChange(key, value) end
        end,
        -- "moved" here means OVERRIDDEN BY THIS ZONE, which is the distinction an
        -- admin actually needs: not "differs from the shipped default" but "this
        -- zone owns this number, and deleting the zone takes it with them".
        moved = function(key)
            local d, z = opts.draft(), opts.zone()
            return (d and z) and d:isOverride(z, key) or false
        end,
        enabled = function()
            return opts.draft() ~= nil and opts.zone() ~= nil
        end,
    }
    form._skipped = skipped
    return form
end

-- Field names this form had to leave out, so a host can say so rather than
-- letting an admin conclude the store does not have them.
function LMFieldForm.skipped(form)
    return form and form._skipped or {}
end

return LMFieldForm

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
