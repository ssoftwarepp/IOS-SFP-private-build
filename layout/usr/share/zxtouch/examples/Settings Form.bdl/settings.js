window.addEventListener('ios-sfp-settings', (event) => {
    const data = event.detail || {};
    document.getElementById('account').value = data.account || '';
    document.getElementById('loops').value = data.loops || 1;
    document.getElementById('mode').value = data.mode || 'normal';
    document.getElementById('notify').checked = Boolean(data.notify);
});

window.iosSfpSettingsSubmit = function () {
    const account = document.getElementById('account').value.trim();
    const loops = Number(document.getElementById('loops').value);
    if (!Number.isInteger(loops) || loops < 1) {
        alert('循环次数必须是大于零的整数');
        return false;
    }
    window.webkit.messageHandlers.iosSfpSettings.postMessage({
        action: 'save',
        data: {
            account: account,
            loops: loops,
            mode: document.getElementById('mode').value,
            notify: document.getElementById('notify').checked
        }
    });
    return true;
};
