-- HBHusbandryTab - one Husbandry tab hosting Animals and Hutches.
--
-- WHY ONE TAB. They were two top-level entries in a bar that had reached nine,
-- and they are one domain: the animals, and the things the animals live in.
-- Anyone diagnosing a sick flock needs both within a click of each other, and a
-- top-level name has to explain itself to someone scanning a row of unrelated
-- words whereas a sibling only has to differ from Animals. Same reasoning that
-- put Fleet and Janitor behind the Vehicles tab.
--
-- THIS FILE OWNS ALMOST NOTHING. The strip, the switching, the visibility rules
-- and the onShow dispatch are DFViews (Core) - see that file's header for why
-- that is shared rather than copied, and in particular for the reason switching
-- must be visibility and not drawing over the top. Each view owns everything
-- inside its own rect. What is left here is the tab registration, the two-line
-- statement of which views exist, and one prerender chain.
--
-- ONE PRERENDER CHAIN, INSTALLED HERE. Both views used to install their own,
-- which was fine while they were separate panels. Sharing one panel they would
-- both run and the hidden view's column header would draw over the visible one,
-- because a drawRect has no visibility flag to switch off. So the host installs
-- a single chain and routes it to whichever view is active.

if isServer() then return end

require "DFKit"
require "DFViews"

HBHusbandryTab = HBHusbandryTab or {}
local T = HBHusbandryTab

local function layout(panel, x, y, w, h)
    if not T.views then return end
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)

    -- The strip is claimed FIRST, above anything either view owns, so it stays
    -- put while the body underneath changes completely.
    local strip = R:header(m.btnH + m.gap)
    T.views:layoutStrip(strip.x, strip.y)

    local body = R:rest()
    T.views:layoutActive(panel, body.x, body.y, body.w, body.h)
end

local function build(spec, panel, x, y, w, h)
    -- Animals leads: it is what an admin opens this tab to look at, and Hutches
    -- is where you go deliberately once an animal looks wrong.
    T.views = DFViews.new{
        views = {
            { id = "animals", label = "Animals", w = 82, view = HBAnimalsView,
              tip = "Every animal loaded near you - condition, hunger, thirst and where it is standing." },
            { id = "hutches", label = "Hutches", w = 82, view = HBHutchesView,
              tip = "Coops and hutches near you: dirt, nest-box dirt and how much bedding is left. Hay eats dirt and decays, so this is the view that tells you what needs topping up." },
        },
        relayout = function()
            if T.host then layout(T.host, T.hostX, T.hostY, T.hostW, T.hostH) end
        end,
    }

    -- Strip buttons belong to the TAB and are never hidden by a switch, so they
    -- go into neither view's widget list.
    T.views:attachStrip(panel)
    T.views:attachViews(panel)

    -- The single chrome chain. Routed to the active view; a view with no draw
    -- simply contributes nothing.
    local origPrerender = panel.prerender
    panel.prerender = function(self_)
        if origPrerender then origPrerender(self_) end
        if T.views then T.views:draw(self_) end
    end

    T.host = panel
    T.hostX, T.hostY, T.hostW, T.hostH = x, y, w, h

    -- set() rather than assuming the constructor's default: this is what
    -- performs the FIRST visibility pass, so the inactive view starts hidden
    -- rather than drawn on top of the active one until somebody clicks.
    T.views:set("animals")
    layout(panel, x, y, w, h)
end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    local ok, err = pcall(function()
        DFRegistry.registerTab{
            id     = "husbandry",
            label  = "Husbandry",
            order  = 6,   -- where Animals used to sit; Hutches' slot is freed
            build  = build,
            resize = function(_, panel, w, h) layout(panel, 0, 0, w, h) end,
        }
    end)
    if not ok then print("[Husbandry] HBHusbandryTab registerTab error: " .. tostring(err)) end
    print("[Husbandry] HBHusbandryTab registered into Dragonfly (Animals | Hutches)")
end)
