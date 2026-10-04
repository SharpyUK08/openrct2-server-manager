function noise(x, y) {
    var n = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
    return (n - Math.floor(n)) * 2 - 1;
}

function main() {
    var finished = false;
    context.subscribe("interval.tick", function () {
        if (finished) return;
        finished = true;

        var width = map.size.x;
        var height = map.size.y;
        var flatHeight = 14;
        var mountainWidth = Math.max(14, Math.min(22, Math.floor(Math.min(width, height) / 5)));
        var removed = 0;

        for (var y = 0; y < height; y++) {
            for (var x = 0; x < width; x++) {
                var tile = map.getTile(x, y);
                var keepFlat = false;
                for (var k = 0; k < tile.numElements; k++) {
                    var kind = tile.getElement(k).type;
                    if (kind === "footpath" || kind === "entrance") keepFlat = true;
                }

                for (var i = tile.numElements - 1; i >= 0; i--) {
                    var element = tile.getElement(i);
                    if (element.type !== "surface" && element.type !== "footpath" && element.type !== "entrance") {
                        tile.removeElement(i);
                        removed++;
                    }
                }

                var surface = null;
                for (var j = 0; j < tile.numElements; j++) {
                    var candidate = tile.getElement(j);
                    if (candidate.type === "surface") {
                        surface = candidate;
                        break;
                    }
                }
                if (surface === null) continue;

                var target = flatHeight;
                if (!keepFlat && x > 0 && y > 0 && x < width - 1 && y < height - 1) {
                    var edgeDistance = Math.min(x - 1, y - 1, width - 2 - x, height - 2 - y);
                    if (edgeDistance < mountainWidth) {
                        var t = (mountainWidth - edgeDistance) / mountainWidth;
                        var undulation = noise(x, y) * 2.5 * t + Math.sin((x + y) * 0.23) * 1.5 * t;
                        target = flatHeight + 2 * Math.max(0, Math.round(t * t * 18 + undulation));
                    }
                }

                surface.baseHeight = target;
                surface.clearanceHeight = target;
                surface.slope = 0;
                surface.waterHeight = 0;
                surface.grassLength = 0;
                if (!keepFlat && x > 0 && y > 0 && x < width - 1 && y < height - 1) {
                    surface.ownership = 16;
                }
            }
        }

        park.name = "Mountain Rim Sandbox";
        park.setFlag("noMoney", true);
        park.setFlag("open", false);
        park.setFlag("forbidHighConstruction", false);
        park.setFlag("forbidLandscapeChanges", false);
        park.setFlag("forbidTreeRemoval", false);
        park.setFlag("forbidMarketingCampaigns", false);
        cheats.sandboxMode = true;
        cheats.ignoreResearchStatus = true;
        cheats.disableSupportLimits = true;
        date.monthsElapsed = 0;
        date.monthProgress = 0;

        context.saveGame({ filename: "Mountain Rim Sandbox" });
        console.log("MOUNTAIN_SANDBOX_SAVED size=" + width + "x" + height + " removed=" + removed);
    });
}

registerPlugin({
    name: "Mountain Rim Sandbox Generator",
    version: "1.0.0",
    authors: "Codex",
    type: "remote",
    licence: "MIT",
    targetApiVersion: 122,
    minApiVersion: 122,
    main: main
});
