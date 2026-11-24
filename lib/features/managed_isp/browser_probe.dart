import 'dart:convert';

String ispBrowserProbePage({required bool chinese, required String nonce}) {
  final title = chinese ? 'Chrome 环境探测' : 'Chrome environment probe';
  final hint = chinese
      ? '先在当前窗口通过 chrome://version 核对 Profile Path。只填你获准探测的地址。HTTPS 端点需允许跨域读取，WebRTC 是单独的测试。'
      : 'Verify Profile Path in chrome://version in this window. Enter only authorized endpoints. The HTTPS endpoint must allow CORS. WebRTC is a separate test.';
  final run = chinese ? '运行探测' : 'Run probes';
  final copy = chinese
      ? '选中结果，复制回 FlClash'
      : 'Select and copy the result into FlClash';
  return '''
<!doctype html>
<html lang="${chinese ? 'zh' : 'en'}">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; connect-src https: stun: stuns: turn: turns:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<title>$title</title>
<style>
  body { color-scheme: light dark; font: 16px system-ui; max-width: 40rem; margin: 8vh auto; padding: 1rem; }
  label,textarea,input { display:block; box-sizing:border-box; width:100%; margin:.5rem 0; }
  button,input,textarea { font:inherit; padding:.5rem; }
</style>
<h1>$title</h1><p>$hint</p>
<label>HTTPS<input id="https" type="url" placeholder="https://probe.example.test/"></label>
<label>STUN / TURN<input id="ice" placeholder="stun:probe.example.test:3478"></label>
<label>TURN username<input id="user" autocomplete="off"></label>
<label>TURN password<input id="secret" type="password" autocomplete="off"></label>
<button id="run">$run</button>
<label>$copy<textarea id="result" data-nonce="${htmlEscape.convert(nonce)}" rows="9" readonly></textarea></label>
$_probeScript''';
}

const _probeScript = r'''
<script>
  const byId = id => document.getElementById(id);
  const kinds = new Set(['host', 'srflx', 'prflx', 'relay']);
  function addressClass(address) {
    if (!address) return 'unknown';
    const value = address.toLowerCase().replaceAll('[', '').replaceAll(']', '');
    if (value.endsWith('.local')) return 'mdns';
    if (value.startsWith('::ffff:')) return addressClass(value.slice(7));
    if (value.includes(':')) {
      if (value === '::' || value === '::1' || /^fe[89ab]/.test(value) || value.startsWith('ff')) return 'local';
      if (/^f[cd]/.test(value)) return 'private';
      if (/^[23]/.test(value) && !/^2001:db8:/.test(value)) return 'public';
      return 'unknown';
    }
    const parts = value.split('.').map(Number);
    if (parts.length !== 4 || parts.some(n => !Number.isInteger(n) || n > 255 || n < 0)) return 'unknown';
    const [a, b, c] = parts;
    if (a === 0 || a === 127 || a === 169 && b === 254 || a >= 224) return 'local';
    if (a === 10 || a === 172 && b >= 16 && b <= 31 || a === 192 && b === 168 || a === 100 && b >= 64 && b <= 127) return 'private';
    if (a === 192 && b === 0 && c === 2 || a === 198 && b === 51 && c === 100 || a === 203 && b === 0 && c === 113 || a === 198 && (b === 18 || b === 19)) return 'unknown';
    return 'public';
  }
  async function testHttps(value) {
    if (!value) return 'skipped';
    try {
      const url = new URL(value);
      if (url.protocol !== 'https:' || url.username || url.password || url.hash) return 'failed';
      const response = await fetch(url, {signal: AbortSignal.timeout(9000), credentials: 'omit', redirect: 'error', cache: 'no-store'});
      await response.body?.cancel();
      return response.ok ? 'passed' : 'failed';
    } catch (e) {
      return e.name === 'TimeoutError' ? 'timeout' : 'failed';
    }
  }
  async function testIce(value, username, credential, report) {
    if (!value) return 'skipped';
    if (!/^(stun|stuns|turn|turns):[^\s/@]+$/i.test(value)) return 'failed';
    let connection;
    let timer;
    try {
      const relay = /^turns?:/i.test(value);
      connection = new RTCPeerConnection({iceServers: [relay ? {urls: value, username, credential} : {urls: value}]});
      connection.createDataChannel('diagnostics');
      return await new Promise(resolve => {
        timer = setTimeout(() => resolve('timeout'), 12000);
        connection.addEventListener('icecandidate', ({candidate}) => {
          if (!candidate) return;
          const kind = kinds.has(candidate.type) ? candidate.type : 'unknown';
          const key = [kind, addressClass(candidate.address), addressClass(candidate.relatedAddress)].join('/');
          report.counts[key] = (report.counts[key] || 0) + 1;
          report.candidateCount++;
        });
        connection.addEventListener('icegatheringstatechange', () => {
          if (connection.iceGatheringState === 'complete') resolve('passed');
        });
        connection.createOffer().then(offer => connection.setLocalDescription(offer)).catch(() => resolve('failed'));
      });
    } catch (_) {
      return 'failed';
    } finally {
      clearTimeout(timer);
      connection?.close();
    }
  }
  byId('run').onclick = async () => {
    byId('run').disabled = true;
    byId('result').value = '';
    const report = {
      version: 1, nonce: byId('result').dataset.nonce, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      candidateCount: 0, counts: {},
    };
    try {
      [report.https, report.ice] = await Promise.all([
        testHttps(byId('https').value.trim()),
        testIce(byId('ice').value.trim(), byId('user').value, byId('secret').value, report),
      ]);
      byId('result').value = JSON.stringify(report, null, 2);
      byId('result').select();
    } finally {
      byId('secret').value = '';
      byId('run').disabled = false;
    }
  };
</script>
''';
