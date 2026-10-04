// Lightweight behaviour checks for the installer-embedded OpenRCT2 helper.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const installer = fs.readFileSync(path.join(__dirname, '..', 'outputs', 'install-openrct2-manager.sh'), 'utf8');
const source = installer.split("HELPER_SOURCE = r'''", 2)[1].split("'''", 1)[0]
    .replace('__BLOCKED_HASHES__', '[]')
    .replace('__ROLE_OVERRIDES__', '{}')
    .replace('__SNAPSHOT_MINUTES__', '0')
    .replace('__CONTROL_PORT__', '11754')
    .replace('__CONTROL_TOKEN__', '"test-token"');

const hooks = {};
const saved = [];
const messages = [];
const logs = [];
const adminHash = 'a'.repeat(40);
const playerHash = 'b'.repeat(40);
const players = [
    { id: 1, name: 'Admin', group: 0, publicKeyHash: adminHash },
    { id: 2, name: 'Player', group: 2, publicKeyHash: playerHash },
];
let listener;
const context = {
    subscribe(name, callback) { hooks[name] = callback; },
    setInterval() {},
    saveGame(options) { saved.push(options.filename); },
};
const network = {
    mode: 'server',
    players,
    currentPlayer: { id: 99 },
    getPlayer(id) { return players.find(player => player.id === id); },
    sendMessage(message, recipients) { messages.push({ message, recipients }); },
    createListener() {
        listener = {
            events: {},
            on(name, callback) { this.events[name] = callback; },
            listen() {},
        };
        return listener;
    },
};
let plugin;
vm.runInNewContext(source, {
    context,
    network,
    console: { log(message) { logs.push(String(message)); } },
    registerPlugin(metadata) { plugin = metadata; },
    Date,
    JSON,
});
plugin.main();

function request(payload) {
    let response;
    const socket = {
        events: {},
        on(name, callback) { this.events[name] = callback; },
        end(data) { response = JSON.parse(data); },
    };
    listener.events.connection(socket);
    socket.events.data(JSON.stringify({ token: 'test-token', ...payload }) + '\n');
    return response;
}

const denied = { player: 2, message: '/save' };
hooks['network.chat'](denied);
hooks['interval.tick']();
assert.equal(denied.message, '');
assert.equal(saved.length, 0);
assert(messages.some(item => item.message.includes('administrators only')));

const allowed = { player: 1, message: '/save' };
hooks['network.chat'](allowed);
hooks['interval.tick']();
assert.equal(allowed.message, '');
assert.match(saved[0], /^quick-save-\d{8}T\d{9}Z$/);
assert(messages.some(item => item.message.includes('Quick save ready')));
hooks['network.chat']({ player: 1, message: '/save' });
hooks['interval.tick']();
assert.equal(saved.length, 1);
assert(messages.some(item => item.message.includes('Wait 30 seconds')));

assert.equal(request({ action: 'set_role', hash: playerHash, group: 0 }).ok, true);
hooks['interval.tick']();
assert.equal(players[1].group, 0);
assert.equal(request({ action: 'set_role', hash: playerHash, group: 2 }).ok, true);
const revoked = { player: 2, message: '/save' };
hooks['network.chat'](revoked);
assert.equal(revoked.message, '');
assert.equal(saved.length, 1);
hooks['interval.tick']();
assert.equal(players[1].group, 2);
assert.equal(request({ action: 'set_role', hash: playerHash, group: 7 }).ok, false);
assert.equal(request({ action: 'set_role', hash: '../bad', group: 0 }).ok, false);
assert.equal(request({ token: 'wrong', action: 'set_role', hash: playerHash, group: 0 }).ok, false);

assert(logs.some(line => line.includes('Saved quick park')));
console.log('OpenRCT2 helper behaviour checks passed');
