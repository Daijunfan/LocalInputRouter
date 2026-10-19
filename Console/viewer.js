import RFB from './novnc/core/rfb.js';

const tell = (op, extra = {}) => window.webkit.messageHandlers.console.postMessage({ op, ...extra });

// noVNC's raw-channel interface carries the existing authenticated TCP tunnel.
// A receive completes before Swift reads another chunk, keeping frames bounded.
class NativeChannel {
    constructor() {
        this.readyState = 'connecting';
        this.protocol = 'binary';
        this.binaryType = 'arraybuffer';
        this.onopen = null;
        this.onmessage = null;
        this.onerror = null;
        this.onclose = null;
    }
    send(bytes) {
        tell('send', { bytes: btoa(String.fromCharCode(...bytes)) });
    }
    close() {
        this.readyState = 'closed';
        tell('close');
    }
    open() {
        this.readyState = 'open';
        this.onopen?.();
    }
    receive(bytes) {
        const data = Uint8Array.from(atob(bytes), c => c.charCodeAt(0));
        this.onmessage?.({ data: data.buffer });
    }
    end() {
        this.readyState = 'closed';
        this.onclose?.({ wasClean: true, code: 1000 });
    }
}

window.startDJFConsole = password => {
    const channel = new NativeChannel();
    const status = text => {
        document.getElementById('status').textContent = text;
        tell('status', { text });
    };
    const rfb = new RFB(document.getElementById('desktop'), channel, {
        shared: true, credentials: { password },
    });
    rfb.scaleViewport = true;
    rfb.resizeSession = false;
    rfb.background = '#101418';
    rfb.addEventListener('connect', () => status('已连接 DJF-Windows 共享实体桌面'));
    rfb.addEventListener('disconnect', () => status('共享桌面已断开，请重新连接'));
    rfb.addEventListener('securityfailure', () => status('共享桌面认证失败'));
    rfb.addEventListener('credentialsrequired', () => status('共享桌面设备认证尚未就绪'));
    window.djfConsole = channel;
    document.getElementById('reconnect').onclick = () => tell('restart');
    tell('start');
};
