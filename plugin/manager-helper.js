/* OpenRCT2 Server Manager remote helper. Generated config values use __TOKENS__. */
var blockedHashes = __BLOCKED_HASHES__;
var roleOverrides = __ROLE_OVERRIDES__;
var commandAccess = __COMMAND_ACCESS__;
var snapshotMinutes = __SNAPSHOT_MINUTES__;
var autoPauseWhenEmpty = __PAUSE_WHEN_EMPTY__;
var controlPort = __CONTROL_PORT__;
var callbackPort = __CALLBACK_PORT__;
var controlToken = __CONTROL_TOKEN__;
var seen = {};
var lastActions = {};
var controlListener = null;
var ticksSincePlayerScan = 0;
var pendingSave = null;
var snapshotDue = false;
var nextSnapshotAt = snapshotMinutes > 0 ? Date.now() + snapshotMinutes * 60000 : 0;
var roleUpdateDue = false;
var lastCommandAt = {};
var motdLines = [];
var permissionRequests = {
    "chat": "PERMISSION_CHAT",
    "terraform": "PERMISSION_TERRAFORM",
    "water": "PERMISSION_SET_WATER_LEVEL",
    "rides": "PERMISSION_BUILD_RIDE",
    "ride-properties": "PERMISSION_RIDE_PROPERTIES",
    "scenery": "PERMISSION_SCENERY",
    "scenery-brush": "PERMISSION_TOGGLE_SCENERY_CLUSTER",
    "paths": "PERMISSION_PATH",
    "clear-landscape": "PERMISSION_CLEAR_LANDSCAPE",
    "staff": "PERMISSION_STAFF",
    "park": "PERMISSION_PARK_PROPERTIES",
    "funding": "PERMISSION_PARK_FUNDING",
    "kick": "PERMISSION_KICK_PLAYER",
    "groups": "PERMISSION_MODIFY_GROUPS",
    "cheats": "PERMISSION_CHEAT",
    "scenario": "PERMISSION_EDIT_SCENARIO_OPTIONS"
};
var knownCommands = ["help", "motd", "status", "players", "request", "save", "backup", "restart"];
var restrictedCommands = ["save", "backup", "restart"];
var callbackOutbox = [];
var callbackActive = false;
var callbackSequence = 0;
var autoPauseRequested = false;
var lastParkTick = date.ticksElapsed;
var lastParkTickChangedAt = Date.now();

function playerHash(player) {
    return player ? String(player.publicKeyHash || "").toLowerCase() : "";
}

function groupPermissions(player) {
    try { return network.getGroup(player.group).permissions || []; } catch (error) { return []; }
}

function canUse(player, command) {
    if (!player || !/^[0-9a-f]{40}$/.test(playerHash(player))) return false;
    if (restrictedCommands.indexOf(command) === -1) return true;
    var grants = commandAccess[playerHash(player)] || [];
    if (grants.indexOf("*") !== -1 || grants.indexOf(command) !== -1) return true;
    if (player.group === 0) return true;
    var permissions = groupPermissions(player);
    if (command === "save") return permissions.indexOf("park_properties") !== -1;
    return permissions.indexOf("modify_groups") !== -1;
}

function applyRoleOverrides() {
    for (var i = 0; i < network.players.length; i++) {
        var player = network.players[i];
        var hash = playerHash(player);
        if (!Object.prototype.hasOwnProperty.call(roleOverrides, hash) || player.group === roleOverrides[hash]) continue;
        try { player.group = roleOverrides[hash]; } catch (error) {
            console.log("[MANAGER] Could not apply saved group to " + hash.slice(0, 10) + ": " + error);
        }
    }
}

function drainCallbackOutbox() {
    if (callbackActive || callbackOutbox.length === 0) return;
    callbackActive = true;
    var item = callbackOutbox[0], socket = null, acknowledged = false, finished = false, buffer = "";
    function complete(success, reason) {
        if (finished) return; finished = true; callbackActive = false;
        if (success) {
            callbackOutbox.shift();
            context.setTimeout(drainCallbackOutbox, 1);
            return;
        }
        item.attempts++;
        var delay = Math.min(30000, 500 * Math.pow(2, Math.min(item.attempts, 6)));
        console.log("[MANAGER] Callback " + item.payload.action + " retry in " + delay + "ms: " + reason);
        context.setTimeout(drainCallbackOutbox, delay);
    }
    try {
        socket = network.createSocket(); socket.setNoDelay(true);
        socket.on("data", function (chunk) {
            buffer += chunk;
            if (buffer.length > 2048) { socket.destroy({}); complete(false, "oversized response"); return; }
            var end = buffer.indexOf("\n"); if (end < 0) return;
            try {
                var response = JSON.parse(buffer.slice(0, end));
                acknowledged = response.ok === true;
                socket.end();
                complete(acknowledged, response.status || "rejected");
            } catch (error) { socket.destroy({}); complete(false, "invalid response"); }
        });
        socket.on("error", function (error) { complete(false, String(error)); });
        socket.on("close", function () { if (!acknowledged) complete(false, "connection closed"); });
        socket.connect(callbackPort, "127.0.0.1", function () {
            socket.write(JSON.stringify(item.payload) + "\n");
        });
        context.setTimeout(function () {
            if (!finished) { try { socket.destroy({}); } catch (error) {} complete(false, "timeout"); }
        }, 3000);
    } catch (error) { complete(false, String(error)); }
}

function callbackManager(action, player, fields) {
    if (callbackOutbox.length >= 64) {
        console.log("[MANAGER] Callback outbox full; rejected " + action);
        return false;
    }
    callbackSequence++;
    var payload = { token: controlToken, action: action, player_id: player.id,
        player_name: player.name, public_key_hash: playerHash(player),
        event_id: playerHash(player).slice(0, 12) + "-" + Date.now() + "-" + callbackSequence };
    fields = fields || {};
    Object.keys(fields).forEach(function (key) { payload[key] = fields[key]; });
    callbackOutbox.push({ payload: payload, attempts: 0 });
    drainCallbackOutbox();
    return true;
}

function privateMessage(player, message) {
    if (player) network.sendMessage("Manager: " + message, [player.id]);
}

function validMotd(lines) {
    return Array.isArray(lines) && lines.length <= 5 && lines.every(function (line) {
        return typeof line === "string" && line.length > 0 && line.length <= 180 && !/[\r\n\x00-\x1f]/.test(line);
    });
}

function sendMotd(player) {
    if (!player) return;
    if (!motdLines.length) { privateMessage(player, "No message of the day has been set."); return; }
    motdLines.forEach(function (line) { network.sendMessage(line, [player.id]); });
}

function command(event, player, name, argument) {
    event.message = "";
    if (!canUse(player, name)) {
        privateMessage(player, "You do not have permission to use /" + name + ". Try /request or ask a portal administrator.");
        console.log("[MANAGER] Denied /" + name + " from " + (player ? player.name : "unknown"));
        return;
    }
    if (name === "request") {
        argument = String(argument || "").toLowerCase();
        if (argument === "help" || !argument) {
            privateMessage(player, "Requestable permissions: " + Object.keys(permissionRequests).join(", "));
            return;
        }
        if (!Object.prototype.hasOwnProperty.call(permissionRequests, argument)) {
            privateMessage(player, "Unknown permission. Use /request help to see the allowed names.");
            return;
        }
    }
    if (name === "save" && argument && !/^[a-z0-9][a-z0-9_-]{0,23}$/i.test(argument)) {
        privateMessage(player, "Save labels may use 1-24 letters, numbers, hyphens, or underscores.");
        return;
    }
    var cooldowns = { help: 2, motd: 5, status: 5, players: 5, request: 60, save: 30, backup: 300, restart: 300 };
    var key = playerHash(player) + ":" + name + (name === "request" ? ":" + argument : "");
    var waitSeconds = cooldowns[name] || 30;
    if (lastCommandAt[key] && Date.now() - lastCommandAt[key] < waitSeconds * 1000) {
        privateMessage(player, "Wait " + waitSeconds + " seconds before using /" + name + " again.");
        return;
    }
    lastCommandAt[key] = Date.now();
    if (name === "help") {
        privateMessage(player, "Commands: /motd, /status, /players, /request <permission>, /save [label], /backup, /restart");
    } else if (name === "motd") {
        sendMotd(player);
    } else if (name === "status") {
        privateMessage(player, "Server online; " + network.players.length + " player(s); park " +
            (context.paused ? "paused" : "running") + ".");
    } else if (name === "players") {
        var names = network.players.map(function (item) { return item.name; }).join(", ");
        privateMessage(player, network.players.length + " online: " + names.slice(0, 140));
    } else if (name === "request") {
        if (callbackManager("permission_request", player,
                { permission: permissionRequests[argument], permission_name: argument }))
            privateMessage(player, "Your request for " + argument + " was sent to the portal administrators.");
        else privateMessage(player, "The manager is busy; please try your request again shortly.");
    } else if (name === "save") {
        if (pendingSave) { privateMessage(player, "A save is already pending."); return; }
        var label = argument ? "-" + String(argument).toLowerCase() : "";
        pendingSave = { player: player, prefix: "chat-save" + label };
        privateMessage(player, "Saving a timestamped copy of the current park.");
    } else if (name === "backup") {
        if (callbackManager("backup", player)) privateMessage(player, "Full backup queued.");
        else privateMessage(player, "The manager is busy; the backup was not queued.");
    } else if (name === "restart") {
        // Save from a mutable game hook first. The external worker restarts only after receiving the callback.
        pendingSave = { player: player, prefix: "pre-restart", callback: "restart" };
        network.sendMessage("Manager: Saving now; the server will restart shortly.");
    }
    console.log("[MANAGER] " + player.name + " used /" + name);
}

function groupPayload() {
    return { ok: true, default_group: network.defaultGroup, groups: network.groups.map(function (group) {
        return { id: group.id, name: group.name,
            permissions: group.permissions.map(function (permission) { return "PERMISSION_" + permission.toUpperCase(); }) };
    }) };
}

function statusPayload() {
    var ownId = -1;
    try { ownId = network.currentPlayer.id; } catch (error) {}
    var players = network.players.filter(function (player) { return player.id !== ownId; }).map(function (player) {
        return { id: player.id, name: player.name, group: player.group, ping: player.ping,
            commands_ran: player.commandsRan, money_spent: player.moneySpent, ip_address: player.ipAddress,
            public_key_hash: playerHash(player), last_action: lastActions[player.id] || null };
    });
    var currentParkTick = date.ticksElapsed;
    if (currentParkTick !== lastParkTick) { lastParkTick = currentParkTick; lastParkTickChangedAt = Date.now(); }
    var tickVerifiedPaused = players.length === 0 && Date.now() - lastParkTickChangedAt >= 2000;
    return { ok: true, players: players, paused: context.paused === true || tickVerifiedPaused,
        auto_pause_enabled: autoPauseWhenEmpty,
        auto_paused: autoPauseWhenEmpty && players.length === 0 && (context.paused === true || tickVerifiedPaused),
        park_tick: currentParkTick };
}

function handleControl(request) {
    if (request.action === "status") return statusPayload();
    if (request.action === "groups") return groupPayload();
    if (request.action === "prepare_switch") {
        if (pendingSave) return { ok: false, error: "save_busy" };
        var switchStamp = new Date().toISOString().replace(/[-:.]/g, "");
        var switchFilename = "pre-switch-" + switchStamp;
        context.executeAction("openrct2manager-save", { filename: switchFilename }, function (result) {
            if (result && result.error) console.log("[MANAGER] Pre-switch save failed: " + result.errorMessage);
        });
        return { ok: true, filename: switchFilename + ".park" };
    }
    if (request.action === "chat" && typeof request.message === "string" && request.message.length > 0 &&
            request.message.length <= 180 && !/[\r\n\x00-\x1f]/.test(request.message)) {
        network.sendMessage("Manager: " + request.message); return { ok: true };
    }
    if (request.action === "set_motd" && validMotd(request.lines)) {
        motdLines = request.lines.slice();
        context.sharedStorage.set("openrct2-manager.motd", motdLines);
        return { ok: true, lines: motdLines.slice() };
    }
    if (request.action === "set_snapshot_config" && typeof request.minutes === "number" &&
            request.minutes >= 0 && request.minutes <= 1440 && Math.floor(request.minutes) === request.minutes) {
        snapshotMinutes = request.minutes;
        nextSnapshotAt = snapshotMinutes > 0 ? Date.now() + snapshotMinutes * 60000 : 0;
        return { ok: true };
    }
    if (request.action === "set_role" && /^[0-9a-f]{40}$/.test(String(request.hash || "")) &&
            typeof request.group === "number") {
        roleOverrides[String(request.hash).toLowerCase()] = request.group; roleUpdateDue = true; return { ok: true };
    }
    if (request.action === "set_command_access" && /^[0-9a-f]{40}$/.test(String(request.hash || "")) &&
            typeof request.allowed === "boolean") {
        var hash = String(request.hash).toLowerCase();
        var commandName = request.command === undefined ? "*" : String(request.command).toLowerCase();
        if (commandName !== "*" && restrictedCommands.indexOf(commandName) === -1) return { ok: false };
        var grants = commandAccess[hash] || []; var grantIndex = grants.indexOf(commandName);
        if (request.allowed && grantIndex < 0) grants.push(commandName);
        if (!request.allowed && grantIndex >= 0) grants.splice(grantIndex, 1);
        if (grants.length) commandAccess[hash] = grants; else delete commandAccess[hash];
        return { ok: true, commands: grants.slice() };
    }
    if (request.action === "set_blocked" && /^[0-9a-f]{40}$/.test(String(request.hash || "")) &&
            typeof request.blocked === "boolean") {
        var blockedHash = String(request.hash).toLowerCase(); var blockedIndex = blockedHashes.indexOf(blockedHash);
        if (request.blocked && blockedIndex < 0) blockedHashes.push(blockedHash);
        if (!request.blocked && blockedIndex >= 0) blockedHashes.splice(blockedIndex, 1);
        if (request.blocked) for (var bi = 0; bi < network.players.length; bi++)
            if (playerHash(network.players[bi]) === blockedHash) network.kickPlayer(network.players[bi].id);
        return { ok: true };
    }
    if (request.action === "kick" && typeof request.player_id === "number") {
        network.kickPlayer(request.player_id); return { ok: true };
    }
    if (request.action === "group_create" && typeof request.name === "string") {
        var before = network.groups.map(function (g) { return g.id; }); network.addGroup();
        var created = network.groups.filter(function (g) { return before.indexOf(g.id) < 0; })[0];
        if (!created) return { ok: false }; created.name = request.name; return groupPayload();
    }
    if (request.action === "group_rename" && request.group !== 0) {
        network.getGroup(request.group).name = request.name; return groupPayload();
    }
    if (request.action === "group_delete" && request.group !== 0) {
        network.removeGroup(request.group); return groupPayload();
    }
    if (request.action === "group_default") { network.defaultGroup = request.group; return groupPayload(); }
    if (request.action === "group_permission" && request.group !== 0 && typeof request.allowed === "boolean") {
        var group = network.getGroup(request.group);
        var permission = String(request.permission || "").replace(/^PERMISSION_/, "").toLowerCase();
        var permissions = group.permissions.slice(); var pi = permissions.indexOf(permission);
        if (request.allowed && pi < 0) permissions.push(permission);
        if (!request.allowed && pi >= 0) permissions.splice(pi, 1);
        group.permissions = permissions; return groupPayload();
    }
    return { ok: false };
}

function main() {
    if (network.mode !== "server") return;
    context.registerAction("openrct2manager-save", function (event) {
        var filename = event && event.args && event.args.filename;
        return typeof filename === "string" && /^pre-switch-[0-9TZ]+$/.test(filename)
            ? {} : { error: 1, errorMessage: "Invalid manager save filename" };
    }, function (event) {
        var filename = event.args.filename;
        context.saveGame({ filename: filename });
        console.log("[MANAGER] Saved " + filename + ".park before park switch");
        return {};
    });
    try {
        var storedMotd = context.sharedStorage.get("openrct2-manager.motd");
        if (validMotd(storedMotd)) motdLines = storedMotd.slice();
    } catch (error) { console.log("[MANAGER] Could not load MOTD: " + error); }
    context.subscribe("network.authenticate", function (event) {
        if (blockedHashes.indexOf(String(event.publicKeyHash || "").toLowerCase()) !== -1) event.cancel = true;
    });
    context.subscribe("network.chat", function (event) {
        var player = null; try { player = network.getPlayer(event.player); } catch (error) {}
        var original = String(event.message || "").trim();
        var match = /^\/([a-z][a-z0-9-]*)(?:\s+(.+))?$/i.exec(original);
        var name = match ? match[1].toLowerCase() : "";
        if (name === "autosave" || name === "snapshot") name = "save";
        if (name === "who") name = "players";
        if (name === "commands") name = "help";
        if (knownCommands.indexOf(name) !== -1) { command(event, player, name, match && match[2]); return; }
        console.log("[CHAT] " + (player ? player.name : "Player") + ": " + String(event.message || "").replace(/[\r\n\t]/g, " ").slice(0, 500));
    });
    context.subscribe("network.join", function (event) {
        context.setTimeout(function () {
            var player = null; try { player = network.getPlayer(event.player); } catch (error) {}
            sendMotd(player);
        }, 1500);
    });
    context.subscribe("action.execute", function (event) {
        if (typeof event.player === "number" && event.player >= 0) lastActions[event.player] = event.action;
    });
    context.subscribe("network.leave", function (event) {
        if (typeof event.player === "number") delete lastActions[event.player];
    });
    try {
        controlListener = network.createListener();
        controlListener.on("connection", function (socket) {
            var buffer = "", done = false;
            socket.on("data", function (chunk) {
                if (done) return; buffer += chunk;
                if (buffer.length > 8192) { done = true; socket.end('{"ok":false}'); return; }
                var end = buffer.indexOf("\n"); if (end < 0) return; done = true;
                try { var request = JSON.parse(buffer.slice(0, end));
                    if (request.token !== controlToken) { socket.end('{"ok":false}'); return; }
                    socket.end(JSON.stringify(handleControl(request)));
                } catch (error) { socket.end('{"ok":false}'); }
            });
        });
        controlListener.listen(controlPort, "127.0.0.1");
    } catch (error) { console.log("[MANAGER] Control bridge unavailable: " + error); }
    context.subscribe("interval.tick", function () {
        var ownId = -1;
        try { ownId = network.currentPlayer.id; } catch (error) {}
        var humanPlayers = network.players.filter(function (player) { return player.id !== ownId; }).length;
        if (autoPauseWhenEmpty && humanPlayers === 0 && context.paused !== true && !autoPauseRequested) {
            autoPauseRequested = true;
            context.executeAction("pausetoggle", {}, function (result) {
                autoPauseRequested = false;
                if (result && result.error) console.log("[MANAGER] Auto-pause failed: " + result.errorMessage);
            });
        }
        if (humanPlayers > 0 || context.paused === true) autoPauseRequested = false;
        if (pendingSave) {
            var request = pendingSave; pendingSave = null;
            var stamp = new Date().toISOString().replace(/[-:.]/g, "");
            var filename = request.filename || request.prefix + "-" + stamp;
            try { context.saveGame({ filename: filename });
                console.log("[MANAGER] Saved " + filename + ".park");
                network.sendMessage("Manager: Save ready: " + filename + ".park");
                if (request.callback) callbackManager(request.callback, request.player);
            } catch (error) { console.log("[MANAGER] Save failed: " + error); }
        }
        if (snapshotDue) {
            snapshotDue = false; var snapshotStamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
            try { context.saveGame({ filename: "manager-snapshot-" + snapshotStamp }); }
            catch (error) { console.log("[MANAGER] Snapshot failed: " + error); }
        }
        if (roleUpdateDue) { roleUpdateDue = false; applyRoleOverrides(); }
        if (snapshotMinutes > 0 && nextSnapshotAt > 0 && Date.now() >= nextSnapshotAt) {
            snapshotDue = true;
            nextSnapshotAt = Date.now() + snapshotMinutes * 60000;
        }
        ticksSincePlayerScan++; if (ticksSincePlayerScan < 40) return; ticksSincePlayerScan = 0; applyRoleOverrides();
        var now = Date.now();
        if (Object.keys(lastCommandAt).length > 4096) Object.keys(lastCommandAt).forEach(function (key) {
            if (now - lastCommandAt[key] > 86400000) delete lastCommandAt[key];
        });
        for (var i = 0; i < network.players.length; i++) {
            var player = network.players[i], hash = playerHash(player);
            if (!/^[0-9a-f]{40}$/.test(hash) || seen[hash]) continue;
            try { player.group = player.group; seen[hash] = true; } catch (error) {}
        }
    });
}

registerPlugin({ name:"OpenRCT2 Manager Helper", version:"3.0.0", authors:["OpenRCT2 Manager"],
    type:"remote", licence:"MIT", targetApiVersion:107, minApiVersion:107, main:main });
