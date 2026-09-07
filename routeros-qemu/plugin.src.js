//<script>
(async () => {
  // Build-time variant: 'generic' or 'zte'.  build.sh emits one file per
  // variant from this single source, so a UI change lands in both plug-ins.
  const VARIANT = '__VARIANT__';
  const ZTE = VARIANT === 'zte';
  // ZTE UFI firmware owns br0 and keeps the LAN address on it, so the VM has
  // to join that native bridge instead of the plug-in building its own.
  const TITLE = ZTE ? 'RouterOS虚拟机管理(QEMU)' : 'RouterOS虚拟机管理_QEMU版';
  const MODAL_NAME = ZTE ? 'kano_routeros_qemu_zte_modal' : 'kano_routeros_qemu_modal';
  const STYLE_ID = ZTE ? 'kano_routeros_qemu_zte_style' : 'kano_routeros_qemu_style';
  const NATIVE_BRIDGE = 'br0';
  const MANAGER_VERSION = 2026090615;
  const VM_DIR = '/data/local/mikrotik';
  const MANAGER = `${VM_DIR}/routeros.sh`;
  const CONFIG = `${VM_DIR}/vm.conf`;
  const FORWARDS = `${VM_DIR}/port-forwards.tsv`;
  const DISK = `${VM_DIR}/routeros.img`;
  const TTYD = `${VM_DIR}/ttyd`;
  const TTYD_SOURCES = ['/data/data/com.minikano.f50_sms/ttyd', '/data/data/com.minikano.f50_sms/files/ttyd'];
  const UPLOAD_DIR = '/data/data/com.minikano.f50_sms/files/uploads';
  // Own directory rather than sharing DroidVM_UFI with the UEFI plug-in.
  // Must match BACKUP_ROOT in routeros.sh, which validates restore/delete
  // paths against it.
  const BACKUP_DIR = '/sdcard/RouterOS_QEMU';
  const BOOT_FILE = '/sdcard/ufi_tools_boot.sh';
  // "boot" rather than "start": it applies BOOT_DELAY and detaches so the
  // device's boot script is not held up.  BOOT_LINE_LEGACY is what older
  // versions wrote -- still recognised as "autostart on", and replaced when
  // the user toggles, so an existing install is not silently downgraded to
  // "off" in the UI just because the wording changed.
  const BOOT_LINE = `${MANAGER} boot`;
  const BOOT_LINE_LEGACY = `${MANAGER} start`;
  const DEFAULT_PACKAGE_URL = 'https://pan.kanokano.cn/d/UFI-TOOLS-UPDATE/plugins/routeros-qemu-vm-arm64.tar.gz';
  const CURL_PATH = '/data/data/com.minikano.f50_sms/files/curl';
  const INSTALL_STAGE = '/data/local/tmp/rosq-plugin-install';
  // Replaced at build time by build.sh with the base64 of routeros.sh.
  const MANAGER_B64 = '__MANAGER_B64__';

  // Mirrors load_config() in routeros.sh.  Anything not listed here is
  // rejected on save so a hand-edited vm.conf cannot smuggle in shell.
  const DEFAULTS = {
    ROOT_DEVICE: '/dev/vda',
    VM_CPUS: '4',
    VM_CPU_AFFINITY: 'auto',
    VM_NET_QUEUES: 'auto',
    VM_MEMORY_MIB: '384',
    DISK_SIZE: '1G',
    QEMU_PATH: 'auto',
    VM_VHOST: 'auto',
    QEMU_EXTRA_ARGS: '',
    FIRMWARE_PATH: 'auto',
    FIRMWARE_VARS_PATH: 'auto',
    MACHINE: 'virt',
    CPU_MODEL: 'host',
    ACCEL: 'kvm',
    RNG_ENABLED: '1',
    USB_BUS_ENABLED: '1',
    WAN_MAC: '52:54:00:6d:05:01',
    LAN_MAC: '52:54:00:6d:05:02',
    TTYD_ENABLED: '1',
    TTYD_BIND: '0.0.0.0',
    TTYD_PORT: '7682',
    TTYD_CREDENTIAL: '',
    ROS_USER: 'admin',
    ROS_PASSWORD: '',
    ROS_DNS: '223.5.5.5,119.29.29.29',
    ROS_WAN_IFACE: 'wan',
    ROS_LAN_IFACE: 'lan',
    ROS_ULA_PREFIX: '',
    BOOT_DELAY: '0',
    ROS_DHCP_ENABLED: '1',
    ROS_DHCP_POOL_START: '100',
    ROS_DHCP_POOL_END: '200',
    ROS_DHCP_LEASE: '1h',
    AUTO_TAKEOVER: '0',
    NETWORK_MONITOR: '1',
    IPV6_PASSTHROUGH: '1',
    CELLULAR_IFACE: 'auto',
    CELLULAR_ROUTE_TABLE: 'auto',
    TETHER_IFACE_PATTERNS: 'auto',
    TETHER_MODE: ZTE ? 'directbr0' : 'bridge',
    USB_REPLUG: '1',
    WIFI_DEAUTH: '1',
    STANDALONE: '1',
    SSH_DNAT_PORT: '2224',
    WEB_DNAT_PORT: '8081',
    WINBOX_DNAT_PORT: '8291',
    LAN_HOST_IP: '',
    LAN_GUEST_IP: '192.168.42.253',
    LAN_NETMASK: '255.255.255.0',
  };
  const CONFIG_KEYS = Object.keys(DEFAULTS);

  const state = {
    installed: false,
    running: false,
    bootEnabled: false,
    busy: false,
    busyText: '空闲',
    statusText: '检测中…',
    statusDetail: '',
    progress: { show: false, text: '', pct: 0, indeterminate: false },
    config: { ...DEFAULTS },
    forwards: [],
    usbDevices: [],
    usbAuto: [],
    usbSupport: false,
    diskBytes: 0,
    diskAllocated: 0,
    onlineCpuIds: [],
    hostMemoryMib: 1024,
    managerVersion: 0,
    ufiIp: '',
    ttydState: '',
    takeover: false,
  };

  // ---- small helpers ----
  const q = (sel) => document.querySelector(`#${MODAL_NAME} ${sel}`);
  const shellQuote = (value) => `'${String(value ?? '').replace(/'/g, `'\\''`)}'`;
  const esc = (value) => String(value ?? '')
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;').replaceAll("'", '&#39;');
  // guard() reports failures through this, so it must not be able to throw
  // itself — otherwise the error it is reporting disappears again.
  const toast = (message, ok = true, duration = 5000) => {
    try {
      createToast(message, ok ? 'green' : 'red', duration);
    } catch (e) {
      console[ok ? 'log' : 'error'](`[${TITLE}] ${message}`);
    }
  };
  const formatBytes = (value) => {
    const n = Number(value) || 0;
    if (n < 1024) return `${n} B`;
    if (n < 1048576) return `${(n / 1024).toFixed(1)} KB`;
    if (n < 1073741824) return `${(n / 1048576).toFixed(1)} MB`;
    return `${(n / 1073741824).toFixed(2)} GB`;
  };
  const validIPv4 = (value) => {
    const parts = String(value || '').trim().split('.');
    return parts.length === 4 && parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255);
  };
  const same24 = (a, b) => a.split('.').slice(0, 3).join('.') === b.split('.').slice(0, 3).join('.');
  const getUfiIp = () => String(globalThis.UFI_DATA?.lan_ipaddr || '').trim();
  const timestamp = () => {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
  };

  const runRoot = async (command, timeout = 30000) => {
    const result = await runShellWithRoot(command, timeout);
    return { ok: Boolean(result?.success), text: String(result?.content || '').trim() };
  };

  // i18n helper is provided by the host; fall back to plain text if absent.
  const tr = (key, fallback) => {
    try { return (typeof t === 'function' ? t(key) : '') || fallback; } catch (e) { return fallback; }
  };

  // Confirmation dialog. Deliberately NOT the host's fixedConfirm(): that
  // global does not exist in every UFI build, and a ReferenceError inside an
  // async click handler rejects silently — the button just does nothing.
  // Built on createFixedToast when available, with a self-contained overlay
  // fallback so this can never be the thing that breaks.
  const confirmAsk = (id, title, body, okText, seconds = 5) => new Promise((resolve) => {
    let finished = false;
    let timer = null;
    let closeHost = null;
    const markup = `
      <div style="pointer-events:all;width:88vw;max-width:480px">
        <div class="title" style="margin:0;font-weight:800">${esc(title)}</div>
        <div style="margin-top:10px;font-size:.7rem;line-height:1.75">${body}</div>
        <div style="display:flex;justify-content:flex-end;gap:9px;margin-top:13px">
          <button class="rosq-ask-ok" disabled></button>
          <button class="rosq-ask-cancel">取消</button>
        </div>
      </div>`;
    let host;
    try {
      if (typeof createFixedToast !== 'function') throw new Error('no createFixedToast');
      const fixed = createFixedToast(id, markup);
      host = fixed.el;
      closeHost = fixed.close;
    } catch (e) {
      const overlay = document.createElement('div');
      overlay.style.cssText = 'position:fixed;inset:0;z-index:100003;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center';
      overlay.innerHTML = `<div style="background:#12161c;color:#d6dde6;border:1px solid #2a3340;border-radius:10px;padding:14px">${markup}</div>`;
      document.body.appendChild(overlay);
      host = overlay;
      closeHost = () => overlay.remove();
    }
    const ok = host.querySelector('.rosq-ask-ok');
    // A short countdown keeps a stray double-click from confirming a
    // destructive action, matching the existing plug-in's behaviour.
    let remaining = Math.max(0, Number(seconds) || 0);
    const update = () => {
      if (!ok) return;
      ok.textContent = remaining > 0 ? `${okText}（${remaining}）` : okText;
      ok.disabled = remaining > 0;
    };
    update();
    if (remaining > 0) {
      timer = setInterval(() => {
        remaining -= 1;
        update();
        if (remaining <= 0 && timer) clearInterval(timer);
      }, 1000);
    }
    const done = (value) => {
      if (finished) return;
      finished = true;
      if (timer) clearInterval(timer);
      try { closeHost && closeHost(); } catch (e) { /* already gone */ }
      resolve(value);
    };
    ok?.addEventListener('click', () => { if (remaining <= 0) done(true); });
    host.querySelector('.rosq-ask-cancel')?.addEventListener('click', () => done(false));
  });

  // Every click handler goes through this: an unhandled rejection in an async
  // onclick shows the user nothing at all, which is indistinguishable from a
  // dead button.
  const guard = (fn, label) => async (...args) => {
    try {
      return await fn(...args);
    } catch (e) {
      console.error(`[${TITLE}] ${label || ''}`, e);
      toast(`${label ? `${label}：` : ''}${e?.message || e}`, false, 9000);
      if (state.busy) setBusy(false);
    }
  };

  // Ported from the crosvm RouterOS plug-in: posts the picked file to the
  // UFI backend, which drops it into UPLOAD_DIR, and returns the stored file
  // name.  Everything it leans on (KANO_baseURL, common_headers,
  // createFixedToast, runShellWithUser, validateAlphaAndNumber) is a host
  // global, so this only works inside the UFI web console.
  const uploadFileKano = async (file, needRename = false, maxSizeMB = 512) => {
    if (!file) return null;
    if (file.size > maxSizeMB * 1024 * 1024) {
      createToast(`${tr('file_size_over_limit', '文件超过大小限制')} ${maxSizeMB}MB！`, 'red');
      return null;
    }
    let closeFn = null;
    try {
      const fixed = createFixedToast('rosq_uploading_file', tr('uploading', '正在上传…'));
      closeFn = fixed.close;
      const formData = new FormData();
      formData.append('file', file);
      const res = await (await fetch(`${KANO_baseURL}/upload_img`, {
        method: 'POST',
        headers: common_headers,
        body: formData,
      })).json();
      if (!res.url) throw new Error(res.error || tr('toast_upload_failed', '上传失败'));
      fixed.el.textContent = tr('toast_upload_success', '上传完成');
      fixed.el.style.color = 'pink';
      const stored = res.url.replace('/uploads/', '');
      if (!stored) throw new Error(tr('upload_success_but_cannot_detect_file_name', '上传成功但无法识别文件名'));
      const nameOk = typeof validateAlphaAndNumber === 'function' && validateAlphaAndNumber(file.name);
      if (needRename && nameOk) {
        const mv = await runShellWithUser(`mv ${UPLOAD_DIR}/${stored} ${UPLOAD_DIR}/${file.name}`);
        if (!mv?.success) { createToast(tr('toast_oprate_failed', '操作失败'), 'red'); return null; }
        return file.name;
      }
      return stored;
    } catch (e) {
      console.error(e);
      createToast(`${tr('toast_upload_failed', '上传失败')}${e?.message ? `：${e.message}` : ''}`, 'red');
      return null;
    } finally {
      if (closeFn) closeFn();
    }
  };

  // Opens the browser file picker, uploads, then hands the on-device path to
  // the installer.
  const pickAndInstallLocal = () => {
    if (state.busy) return toast('有操作正在进行', false);
    if (typeof KANO_baseURL === 'undefined' || typeof createFixedToast !== 'function') {
      return toast('当前后台不支持文件上传（缺少 uploadFileKano 依赖）', false, 8000);
    }
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.gz,.tgz,application/gzip';
    input.style.cssText = 'position:fixed;left:-9999px';
    input.onchange = async () => {
      try {
        const file = input.files?.[0];
        if (!file) return;
        // A disk backup is also a .gz; installing one would silently do nothing.
        if (/(?:\.img\.gz$|routeros-backup-|^ros-\d)/i.test(file.name)) {
          throw new Error('这看起来是备份镜像而不是资源包。恢复备份请用「虚拟磁盘与备份 → 备份管理 / 恢复」');
        }
        if (file.size < 1024 * 1024 || file.size > 512 * 1024 * 1024) {
          throw new Error(`资源包大小异常（${formatBytes(file.size)}，应在 1 MB ~ 512 MB 之间）`);
        }
        setBusy(true, '正在上传本地资源包…');
        setProgress(`正在上传 ${file.name}（${formatBytes(file.size)}）…`, 10, true);
        const stored = await uploadFileKano(file);
        if (!stored || !/^[A-Za-z0-9_.-]+$/.test(stored)) throw new Error('上传返回的文件名无效');
        setProgress('上传完成，正在安装…', 40, true);
        setBusy(false);
        await installFromPackage(`${UPLOAD_DIR}/${stored}`, true, { cleanupUpload: true });
      } catch (e) {
        setBusy(false);
        toast(String(e?.message || e), false, 9000);
      } finally {
        input.remove();
      }
    };
    document.body.appendChild(input);
    input.click();
  };

  // Long operations (install, backup, maintenance boots) outlive a single
  // shell call, so they run detached and are polled through a marker file.
  const runRootJob = async (script, name, options = {}) => {
    const { successMarker = '__JOB_OK__', timeout = 900000, pollInterval = 1500, onTick = null } = options;
    const safeName = String(name || 'job').replace(/[^A-Za-z0-9_.-]/g, '_');
    const jobId = `${safeName}-${Date.now()}-${Math.floor(Math.random() * 999999)}`;
    const dir = '/data/local/tmp/rosq-jobs';
    const scriptPath = `${dir}/${jobId}.sh`;
    const log = `${dir}/${jobId}.log`;
    const done = `${dir}/${jobId}.done`;

    const b64 = btoa(String.fromCharCode(...new TextEncoder().encode(script)));
    let start = await runRoot(`mkdir -p ${shellQuote(dir)} && : > ${shellQuote(scriptPath)}`, 15000);
    if (!start.ok) throw new Error('无法创建任务目录');
    for (let i = 0; i < b64.length; i += 4000) {
      const chunk = await runRoot(`printf '%s' ${shellQuote(b64.slice(i, i + 4000))} | base64 -d >> ${shellQuote(scriptPath)}`, 20000);
      if (!chunk.ok) throw new Error('写入任务脚本失败');
    }
    // `A ; B &` would background only B and run A in the foreground, which
    // would block this call for the whole job.  Put the pair inside one
    // nohup'd sh -c so the caller returns immediately and polls instead.
    const inner = `sh ${shellQuote(scriptPath)} > ${shellQuote(log)} 2>&1; echo $? > ${shellQuote(done)}`;
    start = await runRoot(`cd ${shellQuote(dir)} && nohup sh -c ${shellQuote(inner)} >/dev/null 2>&1 &`, 15000);
    if (!start.ok) throw new Error('任务启动失败');

    const deadline = Date.now() + timeout;
    let text = '';
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, pollInterval));
      const probe = await runRoot(`cat ${shellQuote(log)} 2>/dev/null; echo "__RC__=$(cat ${shellQuote(done)} 2>/dev/null)"`, 20000);
      text = probe.text || '';
      const rc = text.match(/__RC__=(\d*)\s*$/)?.[1];
      if (onTick) onTick(text);
      if (rc !== undefined && rc !== '') {
        await runRoot(`rm -f ${shellQuote(scriptPath)} ${shellQuote(log)} ${shellQuote(done)}`, 10000);
        const body = text.replace(/__RC__=\d*\s*$/, '').trim();
        return { ok: rc === '0' && body.includes(successMarker), text: body, rc: Number(rc) };
      }
    }
    await runRoot(`rm -f ${shellQuote(scriptPath)} ${shellQuote(log)} ${shellQuote(done)}`, 10000);
    return { ok: false, text: `${text}\n[超时]`, rc: -1 };
  };

  const setBusy = (busy, text = '') => {
    state.busy = busy;
    state.busyText = busy ? (text || '处理中…') : '空闲';
    if (!busy) state.progress = { show: false, text: '', pct: 0, indeterminate: false };
    renderStatus();
  };
  const setProgress = (text, pct = 0, indeterminate = false) => {
    state.progress = { show: true, text, pct, indeterminate };
    renderProgress();
  };

  // ---- vm.conf ----
  const parseConfig = (text) => {
    const out = {};
    for (const line of String(text || '').split('\n')) {
      const m = line.match(/^([A-Z0-9_]+)='(.*)'$/);
      if (m && CONFIG_KEYS.includes(m[1])) out[m[1]] = m[2].replace(/'\\''/g, "'");
      else {
        const m2 = line.match(/^([A-Z0-9_]+)=(.*)$/);
        if (m2 && CONFIG_KEYS.includes(m2[1])) out[m2[1]] = m2[2].replace(/^'|'$/g, '');
      }
    }
    // Installs written before the NICs were renamed pin the old defaults, so
    // preserving their vm.conf verbatim would leave them on ether1/ether2
    // forever.  Only the exact old defaults are migrated -- a hand-picked name
    // is the user's, and stays.  Safe to do on read: these two keys are used
    // nowhere but the sync script, which renames by the read-only default-name
    // before referencing them, so RouterOS follows along on the next sync.
    if (out.ROS_WAN_IFACE === 'ether1') out.ROS_WAN_IFACE = 'wan';
    if (out.ROS_LAN_IFACE === 'ether2') out.ROS_LAN_IFACE = 'lan';
    return out;
  };
  const serializeConfig = (config) => CONFIG_KEYS
    .map((key) => `${key}='${String(config[key] ?? '').replace(/'/g, `'\\''`)}'`)
    .join('\n') + '\n';

  const validateNetwork = (host, guest) => {
    if (!validIPv4(host) || !validIPv4(guest)) throw new Error('请输入有效 IPv4 地址');
    if (!same24(host, guest)) throw new Error('UFI 与 RouterOS 地址必须处于同一个 /24 网段');
    if (host === guest) throw new Error('RouterOS 地址不能与 UFI 后台地址相同');
    const last = Number(guest.split('.')[3]);
    if (last === 0 || last === 255) throw new Error('RouterOS 地址不能是网络地址或广播地址');
  };

  const validateConfig = (config) => {
    for (const key of ['VM_CPUS', 'VM_MEMORY_MIB', 'SSH_DNAT_PORT', 'WEB_DNAT_PORT', 'WINBOX_DNAT_PORT', 'TTYD_PORT']) {
      if (!/^\d+$/.test(String(config[key]))) throw new Error(`${key} 必须是整数`);
    }
    if (!/^\d+$/.test(String(config.BOOT_DELAY))) throw new Error('开机自启延迟必须是整数秒');
    // Matches the backend's own cap; catching it here means the user sees why
    // instead of a save that appears to work and then fails on the device.
    if (Number(config.BOOT_DELAY) > 900) throw new Error('开机自启延迟最大 900 秒');
    if (Number(config.VM_CPUS) < 1) throw new Error('VM_CPUS 至少为 1');
    if (Number(config.VM_MEMORY_MIB) < 128) throw new Error('RouterOS 至少需要 128 MiB 内存');
    if (!['0', '1'].includes(String(config.STANDALONE))) throw new Error('STANDALONE 只能是 0 或 1');
    // The ZTE build exists precisely because its firmware keeps the LAN
    // address on br0; any other tether mode would build a second bridge
    // and strand the clients.
    if (ZTE && config.TETHER_MODE !== 'directbr0') {
      throw new Error("中兴专用版必须保持 TETHER_MODE='directbr0'（直绑原生 br0）");
    }
    if (!['kvm', 'tcg'].includes(String(config.ACCEL))) throw new Error('ACCEL 只能是 kvm 或 tcg');
    if (config.LAN_NETMASK !== '255.255.255.0') throw new Error('当前版本仅支持 255.255.255.0');
    for (const key of ['WAN_MAC', 'LAN_MAC']) {
      if (!/^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(String(config[key]))) throw new Error(`${key} 不是合法 MAC`);
    }
    if (config.WAN_MAC === config.LAN_MAC) throw new Error('WAN_MAC 与 LAN_MAC 不能相同');
    if (config.TTYD_CREDENTIAL && !String(config.TTYD_CREDENTIAL).includes(':')) {
      throw new Error('TTYD_CREDENTIAL 必须是 用户名:密码 形式');
    }
    validateNetwork(config.LAN_HOST_IP, config.LAN_GUEST_IP);
  };

  // Read vm.conf straight from the device.  install must not decide what to
  // preserve from cached state: a stale or failed read would silently reset
  // the user's settings.
  const readRemoteConfig = async () => {
    const r = await runRoot(`
if [ -r ${shellQuote(CONFIG)} ]; then
  echo __CONF_OK__
  cat ${shellQuote(CONFIG)}
else
  echo __CONF_MISSING__
fi`, 25000);
    if (!r.ok) return { ok: false, missing: false, config: {} };
    if (r.text.includes('__CONF_MISSING__')) return { ok: true, missing: true, config: {} };
    if (!r.text.includes('__CONF_OK__')) return { ok: false, missing: false, config: {} };
    return { ok: true, missing: false, config: parseConfig(r.text) };
  };

  // ZTE-only guards, mirroring the ZTE OpenWrt plug-in: the VM joins br0 as a
  // peer, so br0 must actually own the UFI address and the address we are
  // about to give RouterOS must be free on that segment.
  const ztePrecheck = async (host, guest) => {
    if (!ZTE) return;
    const r = await runRoot(`
BR=${shellQuote(NATIVE_BRIDGE)}
[ -d "/sys/class/net/$BR/bridge" ] || { echo "__ERR__=原生网桥 $BR 不存在，本机可能不是中兴 UFI，请用通用版"; exit 0; }
ip -4 -o addr show dev "$BR" 2>/dev/null | awk '{print $4}' | grep -Fxq ${shellQuote(`${host}/24`)} \
  || { echo "__ERR__=$BR 上没有 ${host}/24，UFI 后台地址与实际不符"; exit 0; }
if command -v ping >/dev/null 2>&1 && ping -I "$BR" -c 1 -W 1 ${shellQuote(guest)} >/dev/null 2>&1; then
  echo "__ERR__=${guest} 在 $BR 上已有设备响应，请换一个地址"
fi
echo __PRECHECK_DONE__`, 40000);
    const err = r.text.match(/__ERR__=([^\n]+)/)?.[1];
    if (err) throw new Error(err);
    if (!r.text.includes('__PRECHECK_DONE__')) throw new Error('br0 预检未完成，请重试');
  };

  // ---- status ----
  const refresh = async () => {
    const probe = await runRoot(`
if [ -x ${shellQuote(MANAGER)} ]; then
  echo __INSTALLED__=1
  echo "__MGRVER__=$(${shellQuote(MANAGER)} version 2>/dev/null)"
  echo "__STATUS__=$(${shellQuote(MANAGER)} status 2>&1 | head -n 1)"
  echo __CONFIG_BEGIN__
  cat ${shellQuote(CONFIG)} 2>/dev/null
  echo __CONFIG_END__
  echo __FWD_BEGIN__
  cat ${shellQuote(FORWARDS)} 2>/dev/null
  echo __FWD_END__
  echo "__DISK__=$(stat -c%s ${shellQuote(DISK)} 2>/dev/null || echo 0)"
  echo "__DISKALLOC__=$(( $(stat -c%b ${shellQuote(DISK)} 2>/dev/null || echo 0) * 512 ))"
else
  echo __INSTALLED__=0
fi
if grep -Fq ${shellQuote(BOOT_LINE)} ${shellQuote(BOOT_FILE)} 2>/dev/null; then echo __BOOT__=1; elif grep -Fq ${shellQuote(BOOT_LINE_LEGACY)} ${shellQuote(BOOT_FILE)} 2>/dev/null; then echo __BOOT__=1; else echo __BOOT__=0; fi
echo "__CPUS__=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's#.*/cpu##' | tr '\\n' ',')"
echo "__MEM__=$(awk '/MemTotal:/ {print int($2 / 1024); exit}' /proc/meminfo)"
`, 40000);

    const text = probe.text || '';
    state.installed = /__INSTALLED__=1/.test(text);
    state.bootEnabled = /__BOOT__=1/.test(text);
    state.managerVersion = Number(text.match(/__MGRVER__=(\d+)/)?.[1] || 0);
    state.hostMemoryMib = Number(text.match(/__MEM__=(\d+)/)?.[1] || 1024);
    state.onlineCpuIds = (text.match(/__CPUS__=([^\n]*)/)?.[1] || '')
      .split(',').filter(Boolean).map(Number);
    state.diskBytes = Number(text.match(/__DISK__=(\d+)/)?.[1] || 0);
    state.diskAllocated = Number(text.match(/__DISKALLOC__=(\d+)/)?.[1] || 0);

    const statusLine = text.match(/__STATUS__=([^\n]*)/)?.[1] || '';
    state.running = statusLine.startsWith('running');
    state.statusDetail = statusLine;
    state.ttydState = statusLine.match(/ttyd=(\S+)/)?.[1] || '';
    state.takeover = statusLine.match(/takeover=(\S+)/)?.[1] === 'on';

    const confBlock = text.split('__CONFIG_BEGIN__')[1]?.split('__CONFIG_END__')[0] || '';
    const parsed = parseConfig(confBlock);
    state.config = { ...DEFAULTS, ...parsed };
    if (!state.config.LAN_HOST_IP) state.config.LAN_HOST_IP = getUfiIp();

    const fwdBlock = text.split('__FWD_BEGIN__')[1]?.split('__FWD_END__')[0] || '';
    state.forwards = fwdBlock.split('\n').map((line) => line.split('\t'))
      .filter((cols) => cols.length >= 6)
      .map(([enabled, name, proto, bind, host, guest]) => ({
        enabled: enabled === '1', name, proto, bind, host, guest,
      }));

    state.statusText = !state.installed
      ? '未安装'
      : (state.running ? '运行中' : (state.diskBytes > 0 ? '已停止' : '未导入 CHR 镜像'));
    render();
  };

  const refreshUsb = async () => {
    if (!state.installed) return;
    const r = await runRoot(`${shellQuote(MANAGER)} usb list 2>/dev/null`, 30000);
    state.usbSupport = /USB_SUPPORT=1/.test(r.text);
    state.usbAuto = (r.text.match(/^AUTO\|(.+)$/gm) || []).map((l) => l.replace('AUTO|', ''));
    state.usbDevices = (r.text.match(/^USB\|.+$/gm) || []).map((line) => {
      const [, name, bus, dev, vid, pid, manufacturer, product, claimed, driver, port] = line.split('|');
      return { name, bus, dev, vid, pid, manufacturer, product, claimed: claimed === '1', driver, port };
    });
    renderUsb();
  };

  // ---- actions ----
  const action = async (verb, label) => {
    if (state.busy) return toast('有操作正在进行', false);
    setBusy(true, label || verb);
    try {
      const r = await runRoot(`${shellQuote(MANAGER)} ${verb} 2>&1`, 300000);
      toast(r.text.split('\n').slice(-3).join('\n') || `${verb} 完成`, r.ok);
    } catch (e) {
      toast(String(e?.message || e), false);
    } finally {
      setBusy(false);
      await refresh();
      await refreshUsb();
    }
  };

  const toggleVm = async () => {
    if (state.busy) return toast('有操作正在进行', false);
    const verb = state.running ? 'stop' : 'start';
    setBusy(true, state.running ? '正在停止…' : '正在启动…');
    setProgress(state.running ? '正在停止虚拟机…' : '正在启动虚拟机…', 0, true);
    try {
      const r = await runRootJob(`
set -u
${shellQuote(MANAGER)} ${verb} 2>&1
echo __VM_ACTION_DONE__
`, `vm-${verb}`, { successMarker: '__VM_ACTION_DONE__', timeout: 300000 });
      toast(r.text.split('\n').filter(Boolean).slice(-2).join('\n') || `${verb} 完成`, r.ok);
    } finally {
      setBusy(false);
      await refresh();
      await refreshUsb();
    }
  };

  const showLogs = async () => {
    const r = await runRoot(`${shellQuote(MANAGER)} logs 160 2>&1 | tail -n 160`, 40000);
    openTextPanel('运行日志', r.text || '（无日志）');
  };

  // ---- install ----
  const ensureTtyd = () => TTYD_SOURCES
    .map((src) => `[ -x ${shellQuote(TTYD)} ] || { [ -f ${shellQuote(src)} ] && cp ${shellQuote(src)} ${shellQuote(TTYD)} && chmod 755 ${shellQuote(TTYD)}; }`)
    .join('\n');

  // The manager script is embedded in this plug-in rather than taken from the
  // package, so "仅更新脚本" can fix the backend without a re-download.
  const writeManagerCommands = () => {
    if (MANAGER_B64.startsWith('__')) throw new Error('请使用 build.sh 生成的构建版插件');
    return MANAGER_B64;
  };

  // Written to a staging file and renamed into place.  Truncating the live
  // manager and appending to it corrupts any copy the shell is still reading
  // (the watchdog and network monitor both run from it), and can fail
  // outright with ETXTBSY while the VM is up.  rename(2) is atomic: running
  // processes keep the old inode, the next invocation gets the new one.
  const MANAGER_STAGE = `${VM_DIR}/.routeros.sh.new`;
  const deployManager = async () => {
    const b64 = writeManagerCommands();
    let r = await runRoot(`mkdir -p ${shellQuote(VM_DIR)} && : > ${shellQuote(MANAGER_STAGE)}`, 20000);
    if (!r.ok) throw new Error('无法创建管理脚本');
    for (let i = 0; i < b64.length; i += 4000) {
      r = await runRoot(`printf '%s' ${shellQuote(b64.slice(i, i + 4000))} | base64 -d >> ${shellQuote(MANAGER_STAGE)}`, 30000);
      if (!r.ok) {
        await runRoot(`rm -f ${shellQuote(MANAGER_STAGE)}`, 10000);
        throw new Error('写入管理脚本失败');
      }
    }
    // Validate before it becomes the live script, so a truncated download can
    // never replace a working manager.
    r = await runRoot(`chmod 755 ${shellQuote(MANAGER_STAGE)} && sh -n ${shellQuote(MANAGER_STAGE)} && echo __SYNTAX_OK__`, 30000);
    if (!r.ok || !r.text.includes('__SYNTAX_OK__')) {
      await runRoot(`rm -f ${shellQuote(MANAGER_STAGE)}`, 10000);
      throw new Error('管理脚本校验失败（内容不完整）');
    }
    r = await runRoot(`mv -f ${shellQuote(MANAGER_STAGE)} ${shellQuote(MANAGER)} && ${shellQuote(MANAGER)} version`, 20000);
    if (!r.ok) throw new Error('管理脚本安装失败');
    return r.text.trim();
  };

  const remoteSize = async (url) => {
    const r = await runRoot(`
CURL=${shellQuote(CURL_PATH)}
[ -x "$CURL" ] || CURL=curl
"$CURL" -sIL --connect-timeout 10 --max-time 30 ${shellQuote(url)} 2>/dev/null \
  | tr -d '\\r' | awk 'tolower($0) ~ /^content-length:/ { v=$2 } END { print (v+0 > 0 ? v+0 : 0) }'`, 45000);
    return Number(String(r.text || '0').split(/\s+/).pop()) || 0;
  };

  const installFromPackage = async (source, isLocal, options = {}) => {
    const { cleanupUpload = false } = options;
    if (state.busy) return toast('有操作正在进行', false);
    const host = getUfiIp();
    if (!validIPv4(host)) return toast('无法从 UFI_DATA.lan_ipaddr 读取有效地址', false);
    const guest = state.config.LAN_GUEST_IP || DEFAULTS.LAN_GUEST_IP;
    try {
      validateNetwork(host, guest);
    } catch (e) {
      return toast(String(e.message), false);
    }

    setBusy(true, '正在安装…');
    setProgress('准备安装…', 0, true);
    try {
      await ztePrecheck(host, guest);
      const total = isLocal ? 0 : await remoteSize(source);
      const fetchCmd = isLocal
        ? `cp ${shellQuote(source)} "$STAGE/pkg.tar.gz"`
        : `CURL=${shellQuote(CURL_PATH)}
[ -x "$CURL" ] || CURL=curl
"$CURL" -L --fail --retry 2 --connect-timeout 20 --max-time 1800 ${shellQuote(source)} -o "$STAGE/pkg.tar.gz"`;

      setProgress(isLocal ? '正在解包本地资源…' : `正在下载资源包${total ? `（${formatBytes(total)}）` : ''}…`, 0, true);
      const r = await runRootJob(`
set -eu
STAGE=${shellQuote(INSTALL_STAGE)}
rm -rf "$STAGE"; mkdir -p "$STAGE"
${fetchCmd}
[ -s "$STAGE/pkg.tar.gz" ] || { echo '资源包为空或下载失败'; exit 2; }
mkdir -p "$STAGE/x"
tar -xzf "$STAGE/pkg.tar.gz" -C "$STAGE/x" || { echo '解压失败（不是 gzip tar？）'; exit 3; }
# Tolerate both a flat archive and one wrapped in a single top directory.
SRC="$STAGE/x"
if [ ! -e "$SRC/edk2-aarch64-code.fd" ] && [ ! -d "$SRC/qemu" ]; then
  for d in "$SRC"/*; do
    [ -d "$d" ] || continue
    { [ -e "$d/edk2-aarch64-code.fd" ] || [ -d "$d/qemu" ]; } || continue
    SRC="$d"; break
  done
fi
{ [ -e "$SRC/edk2-aarch64-code.fd" ] || [ -d "$SRC/qemu" ]; } \
  || { echo '资源包内容不对：既没有 edk2 固件也没有 qemu 目录'; exit 4; }
mkdir -p ${shellQuote(VM_DIR)} ${shellQuote(BACKUP_DIR)}
# The CHR image is NOT shipped in the resource package (MikroTik licensing) —
# the user imports it separately.  Install one only if the package happens to
# carry it and no disk exists yet; never clobber an existing disk.
if [ -e "$SRC/routeros.img" ] && [ ! -s ${shellQuote(DISK)} ]; then
  cp "$SRC/routeros.img" ${shellQuote(DISK)}
  chmod 600 ${shellQuote(DISK)}
fi
for f in edk2-aarch64-code.fd edk2-arm-vars.fd garp ra6 kvm-probe dhcp-relay sparse-writer ttyd; do
  [ -e "$SRC/$f" ] || continue
  cp "$SRC/$f" ${shellQuote(VM_DIR)}/"$f"
done
[ -d "$SRC/qemu" ] && { rm -rf ${shellQuote(VM_DIR)}/qemu; cp -r "$SRC/qemu" ${shellQuote(VM_DIR)}/qemu; }
chmod 755 ${shellQuote(VM_DIR)}/garp ${shellQuote(VM_DIR)}/ra6 ${shellQuote(VM_DIR)}/kvm-probe 2>/dev/null || true
chmod 755 ${shellQuote(VM_DIR)}/dhcp-relay ${shellQuote(VM_DIR)}/sparse-writer ${shellQuote(VM_DIR)}/ttyd 2>/dev/null || true
[ -d ${shellQuote(VM_DIR)}/qemu ] && find ${shellQuote(VM_DIR)}/qemu -type f -name 'qemu-system-*' -exec chmod 755 {} \\; 2>/dev/null || true
${ensureTtyd()}
rm -rf "$STAGE"
echo __INSTALL_OK__
`, 'install', { successMarker: '__INSTALL_OK__', timeout: 1800000 });

      if (!r.ok) throw new Error(r.text.split('\n').filter(Boolean).slice(-3).join('\n') || '安装失败');

      setProgress('正在写入管理脚本…', 70, true);
      await deployManager();

      setProgress('正在写入配置…', 80, true);
      // Updating the resource package must not reset the user's settings.
      // Start from what is already on the device and only fill in keys that
      // are missing, so ROS_PASSWORD / ROS_DNS / ttyd credential / CPU and
      // memory survive an update.
      let existing = {};
      let reinstall = false;
      if (state.installed) {
        const current = await readRemoteConfig();
        if (!current.ok) {
          throw new Error('读取设备上的 vm.conf 失败，已中止安装，以免把你的配置覆盖成默认值');
        }
        existing = current.config;
        reinstall = Object.keys(existing).length > 0;
      }
      const config = reinstall
        ? { ...DEFAULTS, ...existing }
        : { ...DEFAULTS, LAN_HOST_IP: host, LAN_GUEST_IP: guest };
      if (!validIPv4(config.LAN_HOST_IP)) config.LAN_HOST_IP = host;
      if (!validIPv4(config.LAN_GUEST_IP)) config.LAN_GUEST_IP = guest;
      // ttyd is a root console into the router; give it a password up front
      // rather than shipping an open one and hoping the user notices.
      if (!config.TTYD_CREDENTIAL) {
        const rand = Array.from(crypto.getRandomValues(new Uint8Array(6)))
          .map((b) => b.toString(16).padStart(2, '0')).join('');
        config.TTYD_CREDENTIAL = `ros:${rand}`;
      }
      await writeConfig(config);

      setProgress('正在把网络配置写入 RouterOS 磁盘（会启动一次维护实例，约 1-2 分钟）…', 88, true);
      const sync = await runRootJob(`
${shellQuote(MANAGER)} sync-network ${shellQuote(config.LAN_GUEST_IP)} ${shellQuote('255.255.255.0')} 2>&1
echo __SYNC_STAGE_DONE__
`, 'install-sync', { successMarker: '__SYNC_STAGE_DONE__', timeout: 600000 });
      if (!/__NETWORK_SYNC_OK__/.test(sync.text)) {
        toast(`资源已安装，但网络同步失败：${sync.text.split('\n').filter(Boolean).slice(-2).join(' ')}`, false, 9000);
      } else {
        toast(reinstall
          ? `资源已更新，原有配置保留（RouterOS 地址 ${config.LAN_GUEST_IP}）`
          : `安装完成，RouterOS 地址 ${config.LAN_GUEST_IP}，ttyd 凭据 ${config.TTYD_CREDENTIAL}`, true, 9000);
      }
    } catch (e) {
      toast(String(e?.message || e), false, 9000);
    } finally {
      // An uploaded package is a throwaway copy; leaving 40+ MB in the upload
      // directory after every install adds up fast.
      if (cleanupUpload) await runRoot(`rm -f ${shellQuote(source)}`, 20000);
      setBusy(false);
      await refresh();
      await refreshUsb();
    }
  };

  // MikroTik's CHR image is not redistributable, so the plug-in ships without
  // it and the user imports their own chr-<ver>-arm64.img(.zip) here.
  const importDiskImage = () => {
    if (state.busy) return toast('有操作正在进行', false);
    if (!state.installed) return toast('请先安装资源包', false);
    if (typeof KANO_baseURL === 'undefined' || typeof createFixedToast !== 'function') {
      return toast('当前后台不支持文件上传', false, 8000);
    }
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.img,.zip';
    input.style.cssText = 'position:fixed;left:-9999px';
    input.onchange = async () => {
      try {
        const file = input.files?.[0];
        if (!file) return;
        if (!/\.(img|zip)$/i.test(file.name)) throw new Error('只接受 .img 或 .img.zip');
        if (file.size < 1024 * 1024 || file.size > 512 * 1024 * 1024) {
          throw new Error(`镜像大小异常（${formatBytes(file.size)}）`);
        }
        if (state.diskBytes > 0 && !await confirmAsk('rosq_replace_disk', '替换 RouterOS 磁盘',
          `当前已有 ${formatBytes(state.diskBytes)} 的磁盘，导入会<strong style="color:#ff7777">覆盖它，里面的配置全部丢失</strong>。`
          + '<br>建议先到「虚拟磁盘与备份」做一次备份。', '覆盖导入', 5)) return;

        setBusy(true, '正在上传镜像…');
        setProgress(`正在上传 ${file.name}（${formatBytes(file.size)}）…`, 10, true);
        const stored = await uploadFileKano(file);
        if (!stored || !/^[A-Za-z0-9_.-]+$/.test(stored)) throw new Error('上传返回的文件名无效');
        setProgress('上传完成，正在导入…', 50, true);

        const src = `${UPLOAD_DIR}/${stored}`;
        const r = await runRootJob(`
set -eu
SRC=${shellQuote(src)}
STAGE=/data/local/tmp/rosq-image
DISK=${shellQuote(DISK)}
${shellQuote(MANAGER)} stop >/dev/null 2>&1 || true
rm -rf "$STAGE"; mkdir -p "$STAGE"
case "$SRC" in
  *.zip)
    command -v unzip >/dev/null 2>&1 || { echo '设备上没有 unzip'; exit 2; }
    unzip -o -q "$SRC" -d "$STAGE" || { echo '解压失败'; exit 2; }
    IMG="$(find "$STAGE" -type f -name '*.img' | head -n 1)"
    [ -n "$IMG" ] || { echo 'zip 里没有 .img 文件'; exit 3; }
    ;;
  *) IMG="$SRC" ;;
esac
# A CHR image is GPT: protective MBR signature plus an "EFI PART" header at
# LBA 1.  Refuse anything else rather than leave an unbootable disk behind.
dd if="$IMG" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n' | grep -q '55aa' \
  || { echo '不是磁盘镜像（缺少 MBR 签名）'; exit 4; }
dd if="$IMG" bs=1 skip=512 count=8 2>/dev/null | grep -aq 'EFI PART' \
  || { echo '不是 GPT 镜像，CHR 镜像应为 GPT'; exit 4; }
# Import through a temp file so an interrupted copy cannot destroy the disk.
cp "$IMG" "$DISK.import"
mv -f "$DISK.import" "$DISK"
chmod 600 "$DISK"
# The new disk has its own UEFI boot entry; drop the old variable store.
rm -f ${shellQuote(`${VM_DIR}/uefi-vars.fd`)}
rm -rf "$STAGE"
echo "__IMPORT_OK__ $(stat -c%s "$DISK" 2>/dev/null || echo 0)"
`, 'import-image', { successMarker: '__IMPORT_OK__', timeout: 1200000 });

        await runRoot(`rm -f ${shellQuote(src)}`, 20000);
        if (!r.ok) throw new Error(r.text.split('\n').filter(Boolean).slice(-2).join(' ') || '导入失败');

        setProgress('镜像已导入，正在写入网络配置…', 80, true);
        const sync = await runRootJob(`
${shellQuote(MANAGER)} sync-network ${shellQuote(state.config.LAN_GUEST_IP)} ${shellQuote('255.255.255.0')} 2>&1
echo __SYNC_STAGE_DONE__
`, 'import-sync', { successMarker: '__SYNC_STAGE_DONE__', timeout: 600000 });
        toast(/__NETWORK_SYNC_OK__/.test(sync.text)
          ? `镜像导入完成，RouterOS 地址 ${state.config.LAN_GUEST_IP}`
          : `镜像已导入，但网络配置写入失败：${sync.text.split('\n').filter(Boolean).slice(-1)[0] || ''}`,
          /__NETWORK_SYNC_OK__/.test(sync.text), 9000);
      } catch (e) {
        toast(String(e?.message || e), false, 9000);
      } finally {
        setBusy(false);
        input.remove();
        await refresh();
      }
    };
    document.body.appendChild(input);
    input.click();
  };

  const writeConfig = async (config) => {
    const body = serializeConfig(config);
    const b64 = btoa(String.fromCharCode(...new TextEncoder().encode(body)));
    let r = await runRoot(`mkdir -p ${shellQuote(VM_DIR)} && : > ${shellQuote(CONFIG)}`, 20000);
    if (!r.ok) throw new Error('无法写入 vm.conf');
    for (let i = 0; i < b64.length; i += 4000) {
      r = await runRoot(`printf '%s' ${shellQuote(b64.slice(i, i + 4000))} | base64 -d >> ${shellQuote(CONFIG)}`, 20000);
      if (!r.ok) throw new Error('写入 vm.conf 失败');
    }
    await runRoot(`chmod 600 ${shellQuote(CONFIG)}`, 10000);
  };

  const writeForwards = async () => {
    const body = state.forwards
      .map((f) => [f.enabled ? '1' : '0', f.name, f.proto, f.bind || '0.0.0.0', f.host, f.guest].join('\t'))
      .join('\n');
    const b64 = btoa(String.fromCharCode(...new TextEncoder().encode(body ? `${body}\n` : '')));
    let r = await runRoot(`: > ${shellQuote(FORWARDS)}`, 15000);
    if (!r.ok) throw new Error('无法写入端口映射');
    for (let i = 0; i < b64.length; i += 4000) {
      r = await runRoot(`printf '%s' ${shellQuote(b64.slice(i, i + 4000))} | base64 -d >> ${shellQuote(FORWARDS)}`, 20000);
      if (!r.ok) throw new Error('写入端口映射失败');
    }
  };

  // ---- save ----
  const collectForm = () => {
    const config = { ...state.config };
    for (const key of CONFIG_KEYS) {
      const el = q(`[data-key="${key}"]`);
      if (!el) continue;
      config[key] = el.type === 'checkbox' ? (el.checked ? '1' : '0') : String(el.value ?? '').trim();
    }
    return config;
  };

  const save = async (restart) => {
    if (state.busy) return toast('有操作正在进行', false);
    let config;
    try {
      config = collectForm();
      validateConfig(config);
    } catch (e) {
      return toast(String(e.message), false);
    }
    const networkChanged = config.LAN_GUEST_IP !== state.config.LAN_GUEST_IP
      || config.STANDALONE !== state.config.STANDALONE
      || config.ROS_DNS !== state.config.ROS_DNS
      || config.ROS_DHCP_ENABLED !== state.config.ROS_DHCP_ENABLED
      || config.ROS_DHCP_POOL_START !== state.config.ROS_DHCP_POOL_START
      || config.ROS_DHCP_POOL_END !== state.config.ROS_DHCP_POOL_END
      || config.ROS_DHCP_LEASE !== state.config.ROS_DHCP_LEASE
      // These two decide which /ipv6 block sync_network_config emits.  Left
      // out, switching the IPv6 mode would write vm.conf, report success, and
      // never reach RouterOS -- the guest would keep the previous behaviour.
      || config.IPV6_PASSTHROUGH !== state.config.IPV6_PASSTHROUGH
      || config.ROS_ULA_PREFIX !== state.config.ROS_ULA_PREFIX;

    setBusy(true, '正在保存…');
    try {
      await writeConfig(config);
      await writeForwards();
      state.config = config;

      if (networkChanged) {
        await ztePrecheck(config.LAN_HOST_IP, config.LAN_GUEST_IP);
        // LAN address and gateway/standalone role both live inside RouterOS's
        // own configuration, so they can only be changed with the VM stopped.
        // Whether to restart afterwards is decided on the device, from the
        // state at that moment, not from what the UI last saw.
        setProgress('正在把网络配置写入 RouterOS 磁盘…', 30, true);
        const sync = await runSyncJob(config.LAN_GUEST_IP, 'save-sync');
        toast(sync.ok ? '已保存并同步到 RouterOS' : `保存成功，但网络同步失败：${sync.text.split('\n').filter(Boolean).slice(-2).join(' ')}`, sync.ok, 8000);
      } else if (restart && state.running) {
        setProgress('正在重启虚拟机…', 50, true);
        await runRootJob(`${shellQuote(MANAGER)} restart 2>&1; echo __VM_ACTION_DONE__`,
          'save-restart', { successMarker: '__VM_ACTION_DONE__', timeout: 300000 });
        toast('已保存并重启', true);
      } else {
        toast(restart ? '已保存（虚拟机未运行）' : '已保存，下次启动生效', true);
      }
    } catch (e) {
      toast(String(e?.message || e), false);
    } finally {
      setBusy(false);
      await refresh();
    }
  };

  // ---- disk ----
  const expandDisk = async () => {
    const answer = prompt('扩容到多少 GiB？（只能变大，RouterOS 启动后自动扩展分区）',
      String(Math.max(2, Math.ceil(state.diskBytes / 1073741824) + 1)));
    if (!answer) return;
    if (!/^\d+$/.test(answer)) return toast('请输入整数 GiB', false);
    setBusy(true, '正在扩容…');
    try {
      const r = await runRootJob(`
set -u
WAS_RUNNING=0
${shellQuote(MANAGER)} status >/dev/null 2>&1 && WAS_RUNNING=1
[ "$WAS_RUNNING" = 0 ] || ${shellQuote(MANAGER)} stop >/dev/null 2>&1
${shellQuote(MANAGER)} disk-resize ${shellQuote(answer)} expand 2>&1
RC=$?
[ "$WAS_RUNNING" = 0 ] || ${shellQuote(MANAGER)} start >/dev/null 2>&1
[ "$RC" = 0 ] && echo __DISK_OK__
exit "$RC"
`, 'disk-resize', { successMarker: '__DISK_OK__', timeout: 600000 });
      toast(r.text.split('\n').filter(Boolean).slice(-2).join('\n'), r.ok);
    } finally {
      setBusy(false);
      await refresh();
    }
  };

  const reclaimDisk = async () => {
    if (!await confirmAsk('rosq_reclaim', '回收宿主空间', '需要先停止虚拟机，把磁盘镜像重新稀疏化以释放已删除数据占用的存储。', '开始回收', 3)) return;
    setBusy(true, '正在回收…');
    try {
      const r = await runRootJob(`
set -u
WAS_RUNNING=0
${shellQuote(MANAGER)} status >/dev/null 2>&1 && WAS_RUNNING=1
[ "$WAS_RUNNING" = 0 ] || ${shellQuote(MANAGER)} stop >/dev/null 2>&1
${shellQuote(MANAGER)} disk-reclaim 2>&1
RC=$?
[ "$WAS_RUNNING" = 0 ] || ${shellQuote(MANAGER)} start >/dev/null 2>&1
[ "$RC" = 0 ] && echo __DISK_OK__
exit "$RC"
`, 'disk-reclaim', { successMarker: '__DISK_OK__', timeout: 900000 });
      toast(r.text.split('\n').filter(Boolean).slice(-2).join('\n'), r.ok);
    } finally {
      setBusy(false);
      await refresh();
    }
  };

  // ---- backup ----
  const createBackup = async () => {
    const name = prompt('备份名称', `ros-${timestamp()}`);
    if (!name) return;
    if (!/^[A-Za-z0-9_.-]+$/.test(name)) return toast('名称只能包含字母、数字、点、横线和下划线', false);
    setBusy(true, '正在备份…');
    setProgress('正在备份磁盘镜像…', 0, true);
    try {
      const r = await runRootJob(`
set -u
WAS_RUNNING=0
${shellQuote(MANAGER)} status >/dev/null 2>&1 && WAS_RUNNING=1
[ "$WAS_RUNNING" = 0 ] || ${shellQuote(MANAGER)} stop >/dev/null 2>&1
${shellQuote(MANAGER)} backup ${shellQuote(name)} 2>&1
RC=$?
[ "$WAS_RUNNING" = 0 ] || ${shellQuote(MANAGER)} start >/dev/null 2>&1
[ "$RC" = 0 ] && echo __BACKUP_OK__
exit "$RC"
`, 'backup', { successMarker: '__BACKUP_OK__', timeout: 1800000 });
      toast(r.text.split('\n').filter(Boolean).slice(-2).join('\n'), r.ok);
    } finally {
      setBusy(false);
      await refresh();
    }
  };

  const openBackupManager = async () => {
    const r = await runRoot(`${shellQuote(MANAGER)} backups 2>/dev/null`, 30000);
    const rows = (r.text.match(/^BACKUP\|.+$/gm) || []).map((line) => {
      const [, name, path, size] = line.split('|');
      return { name, path, size: Number(size) || 0 };
    });
    if (!rows.length) return toast('还没有备份', false);
    const body = rows.map((b, i) => `${i + 1}. ${b.name}  (${formatBytes(b.size)})`).join('\n');
    const pick = prompt(`选择要恢复的备份序号（留空取消，前缀 d 表示删除，如 d2）：\n${body}`, '');
    if (!pick) return;
    const del = /^d/i.test(pick);
    const index = Number(pick.replace(/^d/i, '')) - 1;
    const target = rows[index];
    if (!target) return toast('序号无效', false);
    if (del) {
      if (!await confirmAsk('rosq_del_backup', '删除备份', `确定删除 ${esc(target.name)}？`, '删除', 3)) return;
      const d = await runRoot(`${shellQuote(MANAGER)} delete-backup ${shellQuote(target.path)} 2>&1`, 60000);
      return toast(d.text, d.ok);
    }
    if (!await confirmAsk('rosq_restore', '恢复备份', `将用 <strong>${esc(target.name)}</strong> 覆盖当前 RouterOS 磁盘，<strong style="color:#ff7777">当前数据会全部丢失</strong>。`, '恢复', 5)) return;
    setBusy(true, '正在恢复…');
    try {
      const res = await runRootJob(`
set -u
${shellQuote(MANAGER)} stop >/dev/null 2>&1 || true
${shellQuote(MANAGER)} restore-backup ${shellQuote(target.path)} 2>&1
RC=$?
[ "$RC" = 0 ] && echo __RESTORE_OK__
exit "$RC"
`, 'restore', { successMarker: '__RESTORE_OK__', timeout: 1800000 });
      toast(res.text.split('\n').filter(Boolean).slice(-2).join('\n'), res.ok);
    } finally {
      setBusy(false);
      await refresh();
    }
  };

  // ---- USB ----
  const usbAttach = async (name) => {
    setBusy(true, '正在直通…');
    try {
      const r = await runRoot(`${shellQuote(MANAGER)} usb attach ${shellQuote(name)} 2>&1`, 120000);
      toast(r.text, r.ok && !/failed/i.test(r.text));
    } finally {
      setBusy(false);
      await refreshUsb();
    }
  };
  const usbDetach = async (port) => {
    setBusy(true, '正在取消直通…');
    try {
      const r = await runRoot(`${shellQuote(MANAGER)} usb detach ${shellQuote(port)} 2>&1`, 120000);
      toast(r.text, r.ok && !/failed/i.test(r.text));
    } finally {
      setBusy(false);
      await refreshUsb();
    }
  };
  const usbAuto = async (vidpid, enable) => {
    const r = await runRoot(`${shellQuote(MANAGER)} usb auto ${enable ? 'add' : 'del'} ${shellQuote(vidpid)} 2>&1`, 30000);
    toast(r.text, r.ok);
    await refreshUsb();
  };

  // The guest-side settings (LAN address, interface names, DHCP server, the
  // /ipv6 block) live inside RouterOS's own config, which can only be written
  // with the VM stopped -- sync boots a throwaway maintenance instance to do
  // it.  Whether to start the VM again afterwards is decided on the device
  // from the state at that moment, not from what the UI last saw.
  const runSyncJob = (guestIp, label) => runRootJob(`
set -u
WAS_RUNNING=0
${shellQuote(MANAGER)} status >/dev/null 2>&1 && WAS_RUNNING=1
[ "$WAS_RUNNING" = 0 ] || ${shellQuote(MANAGER)} stop >/dev/null 2>&1
${shellQuote(MANAGER)} sync-network ${shellQuote(guestIp)} ${shellQuote('255.255.255.0')} 2>&1
SYNC_RC=$?
[ "$WAS_RUNNING" = 0 ] || ${shellQuote(MANAGER)} start >/dev/null 2>&1
exit "$SYNC_RC"
`, label, { successMarker: '__NETWORK_SYNC_OK__', timeout: 600000 });

  // Saving only syncs when a guest-side key actually changed.  That leaves no
  // way to push settings the form cannot compare -- the NIC names migrated on
  // read, or a config the device drifted away from -- so offer it explicitly.
  const syncNetworkNow = async () => {
    if (state.busy) return toast('有操作正在进行', false);
    if (!state.installed) return toast('请先安装资源包', false);
    if (!await confirmAsk('rosq_sync_now', '同步网络配置到 RouterOS',
      '会<strong>停止虚拟机</strong>，启动一次维护实例把 LAN 地址、接口名（wan/lan）、'
      + 'DHCP 服务器和 IPv6 配置写入 RouterOS 磁盘，然后恢复原来的运行状态。'
      + '<br><br>期间客户端会短暂断网，通常一两分钟。', '开始同步', 5)) return;
    setBusy(true, '正在同步…');
    try {
      setProgress('正在把网络配置写入 RouterOS 磁盘…', 30, true);
      const sync = await runSyncJob(state.config.LAN_GUEST_IP, 'manual-sync');
      toast(sync.ok
        ? '网络配置已同步到 RouterOS'
        : `同步失败：${sync.text.split('\n').filter(Boolean).slice(-2).join(' ')}`, sync.ok, 8000);
    } finally {
      setBusy(false);
      await refresh();
    }
  };

  // ---- boot autostart ----
  // Both spellings are stripped before (re)writing, so toggling an install
  // that still carries the legacy line upgrades it instead of ending up with
  // two entries that would each start the VM.
  const dropBootLines = `grep -Fv ${shellQuote(BOOT_LINE)} ${shellQuote(BOOT_FILE)} | grep -Fv ${shellQuote(BOOT_LINE_LEGACY)} > ${shellQuote(`${BOOT_FILE}.tmp`)} && mv ${shellQuote(`${BOOT_FILE}.tmp`)} ${shellQuote(BOOT_FILE)}`;
  const toggleBoot = async () => {
    const enable = !state.bootEnabled;
    const r = await runRoot(enable
      ? `touch ${shellQuote(BOOT_FILE)}; ${dropBootLines}; printf '%s\\n' ${shellQuote(BOOT_LINE)} >> ${shellQuote(BOOT_FILE)}; echo ok`
      : `[ -f ${shellQuote(BOOT_FILE)} ] && { ${dropBootLines}; }; echo ok`, 20000);
    const delay = Number(state.config.BOOT_DELAY || 0);
    toast(r.ok
      ? (enable
        ? (delay > 0 ? `已开启开机自启（开机后延迟 ${delay} 秒启动）` : '已开启开机自启')
        : '已关闭开机自启')
      : '设置失败', r.ok);
    await refresh();
  };

  // Manual counterpart to AUTO_TAKEOVER.  Only meaningful in gateway mode
  // with the VM up, since takeover() itself bails out otherwise.
  const toggleTakeover = async () => {
    if (String(state.config.STANDALONE) === '1') {
      return toast('接管 UFI 流量仅在网关模式下有效，独立设备模式下后端会直接忽略。', false, 8000);
    }
    if (!state.running) return toast('请先启动虚拟机', false);
    const enable = !state.takeover;
    if (enable && !await confirmAsk('rosq_takeover', '接管 UFI 自身流量',
      'UFI 自己发出的流量会改走 RouterOS（经 <code>ros-br</code> 进、<code>ros-wan</code> 出，两次 NAT）。'
      + '<br><strong style="color:#ffb86b">副作用：接管期间 UFI 自身的 IPv6 会被 prohibit 掉</strong>（只覆盖 IPv4），热点客户端的 IPv6 不受影响。',
      '开始接管', 3)) return;
    setBusy(true, enable ? '正在接管…' : '正在取消接管…');
    try {
      const r = await runRoot(`${shellQuote(MANAGER)} ${enable ? 'takeover' : 'untakeover'} 2>&1`, 120000);
      toast(r.text.split('\n').filter(Boolean).slice(-1)[0] || '已完成', r.ok);
    } finally {
      setBusy(false);
      await refresh();
    }
  };

  const uninstall = async () => {
    if (!await confirmAsk('rosq_uninstall', '永久卸载确认',
      `<strong style="color:#ff7777">该操作不可撤销。</strong><br>将停止虚拟机、还原全部网络规则，并删除 <code>${esc(VM_DIR)}</code>（含 RouterOS 磁盘和你在里面的所有配置）。<br>备份目录 <code>${esc(BACKUP_DIR)}</code> 会保留。`,
      '永久卸载', 8)) return;
    setBusy(true, '正在卸载…');
    try {
      const r = await runRootJob(`
${shellQuote(MANAGER)} uninstall 2>&1
echo __UNINSTALL_OK__
`, 'uninstall', { successMarker: '__UNINSTALL_OK__', timeout: 300000 });
      await runRoot(`[ -f ${shellQuote(BOOT_FILE)} ] && grep -Fv ${shellQuote(BOOT_LINE)} ${shellQuote(BOOT_FILE)} > ${shellQuote(`${BOOT_FILE}.tmp`)} && mv ${shellQuote(`${BOOT_FILE}.tmp`)} ${shellQuote(BOOT_FILE)}; echo ok`, 20000);
      toast(r.ok ? '已卸载' : r.text.split('\n').slice(-2).join('\n'), r.ok);
    } finally {
      setBusy(false);
      await refresh();
    }
  };

  // ---- rendering ----
  const renderProgress = () => {
    const box = q('#rosq_progress');
    if (!box) return;
    box.style.display = state.progress.show ? '' : 'none';
    const text = q('#rosq_progress_text');
    const pct = q('#rosq_progress_pct');
    const fill = q('#rosq_progress_fill');
    if (text) text.textContent = state.progress.text || state.busyText;
    if (pct) pct.textContent = state.progress.indeterminate ? '…' : `${state.progress.pct}%`;
    if (fill) fill.style.width = state.progress.indeterminate ? '100%' : `${state.progress.pct}%`;
  };

  const renderStatus = () => {
    const busy = q('#rosq_busy');
    if (busy) busy.textContent = state.busyText;
    const status = q('#rosq_status');
    if (status) status.textContent = state.statusText;
    const detail = q('#rosq_detail');
    if (detail) detail.textContent = state.statusDetail || '—';
    const toggle = q('#rosq_toggle');
    if (toggle) {
      toggle.textContent = state.running ? '停止' : '启动';
      // Nothing to boot until a CHR image has been imported.
      toggle.disabled = state.busy || !state.installed || (!state.running && state.diskBytes <= 0);
      toggle.title = (!state.running && state.diskBytes <= 0) ? '请先导入 CHR 镜像' : '';
    }
    const importBtn = q('#rosq_import_disk');
    if (importBtn) importBtn.disabled = state.busy || !state.installed;
    for (const id of ['rosq_restart', 'rosq_preflight', 'rosq_logs', 'rosq_save', 'rosq_save_restart',
      'rosq_expand_disk', 'rosq_reclaim_disk', 'rosq_backup', 'rosq_restore', 'rosq_uninstall',
      'rosq_ttyd_open', 'rosq_ttyd_restart', 'rosq_ttyd_stop', 'rosq_boot', 'rosq_usb_refresh',
      'rosq_sync']) {
      const el = q(`#${id}`);
      if (el) el.disabled = state.busy || !state.installed;
    }
    const install = q('#rosq_install');
    if (install) install.disabled = state.busy;
    const bootBtn = q('#rosq_boot');
    if (bootBtn) bootBtn.textContent = state.bootEnabled ? '关闭开机自启' : '开启开机自启';
    const takeoverBtn = q('#rosq_takeover');
    if (takeoverBtn) {
      const gateway = String(state.config.STANDALONE) !== '1';
      takeoverBtn.textContent = state.takeover ? '取消接管 UFI 流量' : '接管 UFI 流量';
      takeoverBtn.disabled = state.busy || !state.installed || !gateway || !state.running;
      takeoverBtn.title = gateway ? '' : '仅网关模式有效';
    }
    renderProgress();
  };

  const renderDisk = () => {
    const el = q('#rosq_disk_summary');
    if (!el) return;
    el.textContent = state.diskBytes
      ? `镜像 ${formatBytes(state.diskBytes)}，实际占用 ${formatBytes(state.diskAllocated)}`
      : '尚未导入 CHR 镜像 —— 请在「安装与资源包」里点「导入 CHR 镜像…」';
  };

  const renderForwards = () => {
    const box = q('#rosq_forwards');
    if (!box) return;
    if (!state.forwards.length) {
      box.innerHTML = '<div class="rosq-empty">暂无端口映射。宿主端口经 iptables DNAT 转发到 RouterOS。</div>';
      return;
    }
    box.innerHTML = `<table class="rosq-table"><thead><tr>
      <th>启用</th><th>名称</th><th>协议</th><th>监听</th><th>宿主端口</th><th>虚拟机端口</th><th></th>
    </tr></thead><tbody>${state.forwards.map((f, i) => `<tr>
      <td><input type="checkbox" data-fwd="${i}" data-field="enabled" ${f.enabled ? 'checked' : ''}></td>
      <td><input data-fwd="${i}" data-field="name" value="${esc(f.name)}" size="8"></td>
      <td><select class="select" data-fwd="${i}" data-field="proto">
        <option value="tcp" ${f.proto === 'tcp' ? 'selected' : ''}>tcp</option>
        <option value="udp" ${f.proto === 'udp' ? 'selected' : ''}>udp</option>
      </select></td>
      <td><input data-fwd="${i}" data-field="bind" value="${esc(f.bind)}" size="9"></td>
      <td><input data-fwd="${i}" data-field="host" value="${esc(f.host)}" size="5"></td>
      <td><input data-fwd="${i}" data-field="guest" value="${esc(f.guest)}" size="5"></td>
      <td><button data-fwd-del="${i}">删除</button></td>
    </tr>`).join('')}</tbody></table>`;
    box.querySelectorAll('[data-fwd]').forEach((el) => {
      el.onchange = () => {
        const row = state.forwards[Number(el.dataset.fwd)];
        const field = el.dataset.field;
        row[field] = el.type === 'checkbox' ? el.checked : el.value.trim();
      };
    });
    box.querySelectorAll('[data-fwd-del]').forEach((el) => {
      el.onclick = () => { state.forwards.splice(Number(el.dataset.fwdDel), 1); renderForwards(); };
    });
  };

  const renderUsb = () => {
    const box = q('#rosq_usb_list');
    if (!box) return;
    if (!state.installed) { box.innerHTML = '<div class="rosq-empty">未安装</div>'; return; }
    if (!state.usbDevices.length) { box.innerHTML = '<div class="rosq-empty">没有检测到 USB 设备</div>'; return; }
    const hint = state.usbSupport ? '' : '<div class="rosq-empty">当前不支持直通（需要虚拟机运行中、qemu 带 usb-host、USB_BUS_ENABLED=1）</div>';
    box.innerHTML = hint + state.usbDevices.map((d) => {
      const id = `${d.vid}:${d.pid}`;
      const auto = state.usbAuto.includes(id);
      const label = `${d.manufacturer || ''} ${d.product || ''}`.trim() || d.name;
      return `<div class="rosq-usb-row">
        <div><b>${esc(label)}</b> <span class="rosq-dim">${esc(id)} · ${esc(d.name)}${d.claimed ? ` · 宿主驱动 ${esc(d.driver)}` : ''}</span></div>
        <div>
          <label class="rosq-check"><input type="checkbox" data-usb-auto="${esc(id)}" ${auto ? 'checked' : ''}><span>自动直通</span></label>
          ${d.port
            ? `<button data-usb-detach="${esc(d.port)}" ${state.busy ? 'disabled' : ''}>取消直通</button>`
            : `<button data-usb-attach="${esc(d.name)}" ${state.busy || !state.usbSupport ? 'disabled' : ''}>直通</button>`}
        </div>
      </div>`;
    }).join('');
    box.querySelectorAll('[data-usb-attach]').forEach((el) => { el.onclick = guard(() => usbAttach(el.dataset.usbAttach), 'USB 直通'); });
    box.querySelectorAll('[data-usb-detach]').forEach((el) => { el.onclick = guard(() => usbDetach(el.dataset.usbDetach), 'USB 取消直通'); });
    box.querySelectorAll('[data-usb-auto]').forEach((el) => { el.onchange = guard(() => usbAuto(el.dataset.usbAuto, el.checked), 'USB 自动直通'); });
  };

  const renderForm = () => {
    for (const key of CONFIG_KEYS) {
      const el = q(`[data-key="${key}"]`);
      if (!el) continue;
      if (el.type === 'checkbox') el.checked = String(state.config[key]) === '1';
      else el.value = state.config[key] ?? '';
    }
    // These map to code paths that return early when STANDALONE=1
    // (sync_tether_network / sync_ipv6_downstream / start_monitor / takeover),
    // so leaving them editable in standalone mode invites silent no-ops.
    // TETHER_MODE has a single option on the ZTE build, so greying it out
    // would just look broken; leave it visible there.
    const gatewayOnly = [...(ZTE ? [] : ['TETHER_MODE']), 'AUTO_TAKEOVER', 'IPV6_PASSTHROUGH', 'NETWORK_MONITOR',
      'ROS_DHCP_ENABLED', 'ROS_DHCP_POOL_START', 'ROS_DHCP_POOL_END', 'ROS_DHCP_LEASE', 'ROS_ULA_PREFIX'];
    const standalone = String(state.config.STANDALONE) === '1';
    for (const key of gatewayOnly) {
      const el = q(`[data-key="${key}"]`);
      if (!el) continue;
      el.disabled = standalone;
      const cell = el.closest ? el.closest('.rosq-field') : null;
      if (cell) cell.style.opacity = standalone ? '.45' : '';
      if (cell) cell.title = standalone ? '仅网关模式有效，独立设备模式下不会生效' : '';
    }
    const hint = q('#rosq_mode_hint');
    if (hint) {
      hint.innerHTML = standalone
        ? '独立设备模式：虚拟机只是局域网上的一台设备，<b>不</b>接管热点 / USB / 转网口客户端流量，DHCP 仍由 Android 提供。下面置灰的几项在此模式下不生效。'
        : '网关模式：热点 / USB / 转网口会被挂进 <code>ros-br</code>，它们的 IP 被摘掉、Android 的 DHCP 应答被屏蔽，改由 RouterOS 发地址。<b>切换后已连接的客户端必须重连一次</b>。';
    }
  };

  const render = () => { renderStatus(); renderDisk(); renderForwards(); renderUsb(); renderForm(); };

  // ---- text panel ----
  const openTextPanel = (title, body) => {
    const existing = document.getElementById('rosq_text_panel');
    if (existing) existing.remove();
    const wrap = document.createElement('div');
    wrap.id = 'rosq_text_panel';
    wrap.style.cssText = 'position:fixed;inset:5% 5% 5% 5%;z-index:100002;background:#12161c;color:#d6dde6;border:1px solid #2a3340;border-radius:10px;display:flex;flex-direction:column;';
    wrap.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:center;padding:8px 12px;border-bottom:1px solid #2a3340">
      <b>${esc(title)}</b><button id="rosq_text_close">关闭</button></div>
      <pre style="flex:1;overflow:auto;margin:0;padding:12px;font-size:11px;line-height:1.5;white-space:pre-wrap">${esc(body)}</pre>`;
    document.body.appendChild(wrap);
    wrap.querySelector('#rosq_text_close').onclick = () => wrap.remove();
  };

  const openTtyd = () => {
    const bind = String(state.config.TTYD_BIND || '').trim();
    if (bind === '127.0.0.1' || bind === 'localhost' || bind === '::1') {
      return toast('ttyd 现在只监听设备本机（127.0.0.1），浏览器连不上。把下面的「监听地址」改成 0.0.0.0、填好访问凭据，保存后点「重启 ttyd」即可。', false, 11000);
    }
    if (!state.config.TTYD_CREDENTIAL) {
      return toast('ttyd 监听在 ' + bind + ' 但没有设置访问凭据，后端会拒绝启动。请先填「访问凭据」。', false, 10000);
    }
    // TTYD_BIND is a device-side bind address; it is not necessarily an
    // address the browser can reach (127.0.0.1 would point at the user's own
    // machine).  The UFI console is already served from the device, so reuse
    // whatever host got us here.
    window.open(`http://${location.hostname}:${state.config.TTYD_PORT}/`, '_blank');
  };

  const ensureStyle = () => {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = `
      #${MODAL_NAME} .rosq-wrap{font-size:.72rem;line-height:1.5}
      #${MODAL_NAME} .rosq-scroll{max-height:64vh;overflow:auto;padding-right:4px}
      #${MODAL_NAME} .rosq-card{border:1px solid #2a3340;border-radius:8px;padding:9px 11px;margin-bottom:9px}
      #${MODAL_NAME} .rosq-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:7px}
      #${MODAL_NAME} .rosq-title{font-weight:800}
      #${MODAL_NAME} .rosq-form{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px}
      #${MODAL_NAME} input {padding: 6px;height: 100%;}
      #${MODAL_NAME} .rosq-field{display:flex;flex-direction:column;gap:3px;min-width:0}
      /* Caption rule must not swallow the checkbox row: ".rosq-field>label"
         outranks ".rosq-check" on specificity, so exclude it explicitly. */
      #${MODAL_NAME} .rosq-field>label:not(.rosq-check){opacity:.75;font-size:.66rem}
      /* Only stretch real inputs: a checkbox at width:100% renders as a wide
         box and drags its text out of alignment with the neighbouring cells. */
      #${MODAL_NAME} .rosq-field input:not([type="checkbox"]),
      #${MODAL_NAME} .rosq-field select{width:100%;box-sizing:border-box}
      /* Checkbox cells have no caption row, so bottom-align them with the
         input boxes in the same grid row. */
      #${MODAL_NAME} .rosq-field-check{justify-content:flex-end}
      #${MODAL_NAME} .rosq-check{display:flex;align-items:center;gap:6px;font-size:.66rem;opacity:.9;cursor:pointer;min-height:24px;line-height:1.2}
      #${MODAL_NAME} .rosq-check input[type="checkbox"]{width:auto;flex:0 0 auto;margin:0}
      #${MODAL_NAME} .rosq-check span{flex:1 1 auto}
      #${MODAL_NAME} .rosq-actions{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
      #${MODAL_NAME} .rosq-empty{opacity:.6;padding:6px 0}
      #${MODAL_NAME} .rosq-dim{opacity:.6;font-size:.64rem}
      #${MODAL_NAME} .rosq-table{width:100%;border-collapse:collapse;font-size:.66rem}
      #${MODAL_NAME} .rosq-table th,#${MODAL_NAME} .rosq-table td{border-bottom:1px solid #232b36;padding:3px 4px;text-align:left}
      #${MODAL_NAME} .rosq-usb-row{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:5px 0;border-bottom:1px solid #232b36;flex-wrap:wrap}
      #${MODAL_NAME} .rosq-usb-row>div:last-child{display:flex;align-items:center;gap:8px;flex:0 0 auto}
      /* The auto-passthrough toggle sits next to a button, so keep it from
         growing and pushing the button off the row. */
      #${MODAL_NAME} .rosq-usb-row .rosq-check{white-space:nowrap}
      #${MODAL_NAME} .rosq-usb-row .rosq-check span{flex:0 0 auto}
      #${MODAL_NAME} .rosq-table td input[type="checkbox"]{margin:0;vertical-align:middle}
      #${MODAL_NAME} .rosq-table td{vertical-align:middle}
      #${MODAL_NAME} .rosq-progress-bar{height:5px;background:#222b36;border-radius:3px;overflow:hidden}
      #${MODAL_NAME} .rosq-progress-fill{height:100%;width:0;background:#4a9eff;transition:width .3s}
      #${MODAL_NAME} .rosq-credit{margin-top:9px;padding-top:8px;border-top:1px solid #232b36;font-size:.66rem;opacity:.8;text-align:right}
      #${MODAL_NAME} .rosq-credit a{color:#6cb6ff;text-decoration:none;font-weight:700}
      #${MODAL_NAME} .rosq-credit a:hover{text-decoration:underline}
      #${MODAL_NAME} .rosq-banner{border:1px solid #3a4757;border-radius:8px;padding:8px 10px;margin-bottom:9px;font-size:.66rem}
    `;
    document.head.appendChild(style);
  };

  const field = (label, key, type = 'text') =>
    `<div class="rosq-field"><label>${esc(label)}</label><input data-key="${key}" type="${type}"></div>`;
  const check = (label, key) =>
    `<div class="rosq-field rosq-field-check"><label class="rosq-check"><input data-key="${key}" type="checkbox"><span>${esc(label)}</span></label></div>`;
  const select = (label, key, options) =>
    `<div class="rosq-field"><label>${esc(label)}</label><select class="select" data-key="${key}">${options
      .map(([v, t]) => `<option value="${esc(v)}">${esc(t)}</option>`).join('')}</select></div>`;

  const showHelp = () => openTextPanel('使用帮助', `RouterOS 虚拟机管理（QEMU 版）\n作者 Enceka — https://github.com/enceka

为什么是 QEMU 而不是 crosvm
  RouterOS CHR 的 ARM64 镜像必须经 UEFI 引导（ESP 里是 BOOTAA64.EFI），
  crosvm 没有 pflash/MMIO 固件路径，起不来。QEMU 用 -drive if=pflash
  加载 edk2 即可，宿主内核需要标准 nVHE（非 pKVM）。

${ZTE ? `中兴专用版
  TETHER_MODE 锁定 directbr0：虚拟机直接加入原生 br0，不新建网桥、
  不修改 br0 自身地址。安装或改地址前会校验 br0 确实持有 UFI 的 /24，
  且目标地址在该网段上没有设备响应。

` : ''}网卡分工
  ether1 = ros-wan，点对点连 Android，网段 192.168.66.0/24，上行出口。
  ether2 = ros-lan，${ZTE ? '直接挂进原生 br0' : '接 ros-br'}，客户端侧，LAN_GUEST_IP 落在这里。

两种模式
  独立设备模式（默认，STANDALONE=1）
    只作为局域网上一台设备，不建客户端网桥、不接管热点流量。
    RouterOS 默认路由指向 LAN_HOST_IP，自己能上网。
  网关模式（STANDALONE=0）
    热点 / USB / 转网口客户端交给 RouterOS 转发。
    ether1 配 192.168.66.2，默认路由 192.168.66.1，
    并在 RouterOS 内加一条 srcnat masquerade（宿主只翻译 192.168.66.0/24）。
    切换后已连接的客户端需要重新连接一次。

修改 LAN 地址 / 切换模式
  这些配置在 RouterOS 磁盘里，必须停机写入。保存时插件会自动停机、
  启动一个无外部连通的维护实例、通过串口写配置、再恢复原来的运行状态。
  整个过程约 1-2 分钟。

RouterOS 登录凭据
  维护实例用 vm.conf 里的 ROS_USER / ROS_PASSWORD 登录（默认 admin / 空）。
  你在 RouterOS 里改过密码后，必须同步改这里，否则改 IP 会失败。

端口映射
  QEMU 的 hostfwd 只存在于 user-mode 网卡，本方案走 TAP，
  所以端口映射是宿主 iptables DNAT 到 LAN_GUEST_IP。
  SSH ${state.config.SSH_DNAT_PORT}、Webfig ${state.config.WEB_DNAT_PORT}、WinBox ${state.config.WINBOX_DNAT_PORT} 是内置的，不要和自定义映射冲突。

独立模式下客户端怎么连 RouterOS
  独立模式的虚拟机挂在自己的 ros-br 上，和热点 / USB 客户端不是同一个二层，
  所以客户端 **ping 不到 LAN_GUEST_IP，也不能直接用 WinBox 连它**。
  要从客户端管理，请连 UFI 自己的地址加上面这三个端口，例如
  WinBox 填 <UFI地址>:${state.config.WINBOX_DNAT_PORT}、浏览器开 http://<UFI地址>:${state.config.WEB_DNAT_PORT}。
  想让客户端直接访问 LAN_GUEST_IP，需要切到网关模式。

CPU 绑核
  本机是大小核异构，-cpu host 要求所有 vCPU 在同一簇。
  VM_CPU_AFFINITY=auto 会自动选能装下 VM_CPUS 的最大同构簇，
  装不下就把 VM_CPUS 钳到簇大小。手工指定跨簇会直接报错。

串口终端
  ttyd 默认只监听 127.0.0.1，用于首次配置和救急。
  改成 0.0.0.0 请务必同时设置 TTYD_CREDENTIAL，否则局域网内谁都能连控制台。`);

  const openModal = async () => {
    ensureStyle();
    document.getElementById(MODAL_NAME)?.remove();
    state.ufiIp = getUfiIp();
    const { id, el } = createModal({
      name: MODAL_NAME,
      title: TITLE,
      maxWidth: '840px',
      contentStyle: 'max-height:80vh;',
      showConfirm: false,
      onClose: () => true,
      content: `
      <div class="rosq-wrap">
        <div class="rosq-card" id="rosq_progress" style="display:none">
          <div class="rosq-head"><span class="rosq-title">操作进度</span><span id="rosq_progress_pct">0%</span></div>
          <div id="rosq_progress_text" class="rosq-dim" style="margin-bottom:5px">空闲</div>
          <div class="rosq-progress-bar"><div class="rosq-progress-fill" id="rosq_progress_fill"></div></div>
        </div>
        <div class="rosq-scroll">
          <div class="rosq-banner">${ZTE ? '<b>中兴 UFI 后台专用版</b>：虚拟机直接挂进原生 <code>br0</code>（<code>directbr0</code>），不另建网桥、不动 br0 自身地址。若你的机器不是中兴，请改用通用版。<br>' : ''}RouterOS CHR 走 <b>QEMU + UEFI + KVM</b>（crosvm 不支持 pflash，起不了 CHR）。
            默认<b>独立设备模式</b>不接管客户端流量；切到<b>网关模式</b>后热点 / USB / 转网口客户端由 RouterOS 转发。
            RouterOS 用 SSH / Webfig / WinBox 远程配置，本插件不提供图形控制台。</div>

          <div class="rosq-card">
            <div class="rosq-head"><span class="rosq-title">运行状态</span><span id="rosq_busy">空闲</span></div>
            <div>状态：<b id="rosq_status">检测中…</b></div>
            <div class="rosq-dim" id="rosq_detail" style="margin-top:4px;word-break:break-all">—</div>
            <div class="rosq-actions">
              <button id="rosq_toggle">启动</button>
              <button id="rosq_restart">重启</button>
              <button id="rosq_preflight">运行预检</button>
              <button id="rosq_logs">查看日志</button>
              <button id="rosq_boot">开机自启</button>
              <button id="rosq_takeover">接管 UFI 流量</button>
              <button id="rosq_help">使用帮助</button>
            </div>
            <div class="rosq-form" style="margin-top:8px">
              ${field('开机自启延迟（秒，0 = 不等待）', 'BOOT_DELAY', 'number')}
            </div>
            <div class="rosq-dim" style="margin-top:6px">开机时蜂窝、热点、USB 都还在初始化，
              立刻启动会让建网桥的过程和不断变化的接口打架。设 20–60 秒通常够；改完记得「保存设置」。</div>
          </div>

          <div class="rosq-card">
            <div class="rosq-head"><span class="rosq-title">安装与资源包</span></div>
            <div class="rosq-form">
              <div class="rosq-field" style="grid-column:1/-1">
                <label>在线资源包地址（qemu + edk2 + 辅助程序，通常含 CHR 镜像）</label>
                <input id="rosq_package_url" value="${esc(DEFAULT_PACKAGE_URL)}">
              </div>
            </div>
            <div class="rosq-dim">本地安装会打开浏览器文件选择框，上传 <code>routeros-qemu-vm-arm64.tar.gz</code> 后自动安装并清理上传副本。</div>
            <div class="rosq-dim" style="margin-top:6px">
              资源包里通常已带 CHR 镜像。若你的包不含镜像，或想换一个 RouterOS 版本，可到
              <a href="https://mikrotik.com/download" target="_blank" rel="noopener noreferrer">mikrotik.com/download</a>
              下载 <code>chr-&lt;版本&gt;-arm64.img.zip</code>（7.15 起才有 arm64 CHR），再用「导入 CHR 镜像」上传。
            </div>
            <div class="rosq-actions">
              <button id="rosq_install">在线安装 / 更新资源</button>
              <button id="rosq_install_local">从本地上传安装…</button>
              <button id="rosq_import_disk">导入 CHR 镜像…</button>
              <button id="rosq_update_script">仅更新脚本</button>
            </div>
          </div>

          <div class="rosq-card">
            <div class="rosq-head"><span class="rosq-title">网络</span></div>
            <div class="rosq-form">
              ${select('运行模式', 'STANDALONE', [['1', '独立设备模式（默认）'], ['0', '网关模式（接管客户端）']])}
              ${field('UFI 地址 LAN_HOST_IP', 'LAN_HOST_IP')}
              ${field('RouterOS 地址 LAN_GUEST_IP', 'LAN_GUEST_IP')}
              ${field('子网掩码', 'LAN_NETMASK')}
              ${field('SSH 转发端口', 'SSH_DNAT_PORT', 'number')}
              ${field('Webfig 转发端口', 'WEB_DNAT_PORT', 'number')}
              ${field('WinBox 转发端口', 'WINBOX_DNAT_PORT', 'number')}
              ${field('RouterOS DNS（逗号分隔）', 'ROS_DNS')}
              ${select('网关模式 DHCP 服务器', 'ROS_DHCP_ENABLED', [['1', '由 RouterOS 分配（推荐）'], ['0', '关闭（自己在 RouterOS 里配）']])}
              ${field('DHCP 池起始（末位）', 'ROS_DHCP_POOL_START', 'number')}
              ${field('DHCP 池结束（末位）', 'ROS_DHCP_POOL_END', 'number')}
              ${field('租约时长', 'ROS_DHCP_LEASE')}
              ${select('IPv6 下发方式', 'IPV6_PASSTHROUGH', [['1', 'Android 直通（客户端拿公网地址）'], ['0', 'RouterOS 下发（ULA + NAT66）']])}
              ${field('RouterOS LAN ULA 前缀（留空自动推导）', 'ROS_ULA_PREFIX')}
              ${ZTE
                ? select('接入模式（中兴专用版锁定）', 'TETHER_MODE', [['directbr0', 'directbr0（直绑原生 br0）']])
                : select('接入模式', 'TETHER_MODE', [['bridge', 'bridge'], ['auto', 'auto'], ['routed', 'routed'], ['proxyarp', 'proxyarp'], ['directbr0', 'directbr0']])}
              ${check('启动时自动接管 UFI 流量（会禁用 UFI 自身 IPv6）', 'AUTO_TAKEOVER')}
              ${check('网络监控（自动同步网桥端口）', 'NETWORK_MONITOR')}
            </div>
            <div class="rosq-dim" id="rosq_mode_hint" style="margin-top:6px"></div>
            <div class="rosq-actions" style="margin-top:8px">
              <button id="rosq_sync">同步网络配置并重启</button>
            </div>
            <div class="rosq-dim" style="margin-top:6px">保存设置时，只有改动了地址 / 模式 / DNS / DHCP / IPv6
              才会自动同步。这个按钮可以主动把当前配置重新写入 RouterOS —— 从旧版升级后想让接口改名
              （<code>ether1/2</code> → <code>wan/lan</code>）生效，或怀疑客户机配置和界面对不上时用。</div>
            <div class="rosq-dim" style="margin-top:4px">改地址或切模式需要停机写入 RouterOS 磁盘，保存时会自动完成并恢复原状态。</div>
          </div>

          <div class="rosq-card">
            <div class="rosq-head"><span class="rosq-title">虚拟机资源</span></div>
            <div class="rosq-form">
              ${field('vCPU', 'VM_CPUS', 'number')}
              ${field('内存（MiB）', 'VM_MEMORY_MIB', 'number')}
              ${field('CPU 绑核（auto / none / 6,7）', 'VM_CPU_AFFINITY')}
              ${field('网卡队列（auto 或整数）', 'VM_NET_QUEUES')}
              ${select('加速器', 'ACCEL', [['kvm', 'kvm'], ['tcg', 'tcg（仅排错）']])}
              ${select('vhost-net 加速', 'VM_VHOST', [['auto', 'auto（内核有才用）'], ['off', '强制关闭'], ['on', '强制开启']])}
              ${field('CPU 型号', 'CPU_MODEL')}
              ${check('virtio-rng', 'RNG_ENABLED')}
              ${check('USB 控制器（直通所需）', 'USB_BUS_ENABLED')}
              <div class="rosq-field" style="grid-column:1/-1"><label>QEMU 附加参数</label><input data-key="QEMU_EXTRA_ARGS"></div>
            </div>
          </div>

          <div class="rosq-card">
            <div class="rosq-head"><span class="rosq-title">端口映射</span></div>
            <div id="rosq_forwards"></div>
            <div class="rosq-actions"><button id="rosq_add_forward">新增映射</button></div>
          </div>

          <div class="rosq-card">
            <div class="rosq-head"><span class="rosq-title">USB 直通</span><button id="rosq_usb_refresh">刷新列表</button></div>
            <div id="rosq_usb_list"></div>
          </div>

          <div class="rosq-card">
            <div class="rosq-head"><span class="rosq-title">虚拟磁盘与备份</span></div>
            <div id="rosq_disk_summary" class="rosq-dim">—</div>
            <div class="rosq-dim">备份目录：${esc(BACKUP_DIR)}（镜像操作期间会停机）</div>
            <div class="rosq-actions">
              <button id="rosq_expand_disk">扩容磁盘</button>
              <button id="rosq_reclaim_disk">回收宿主空间</button>
              <button id="rosq_backup">备份镜像</button>
              <button id="rosq_restore">备份管理 / 恢复</button>
            </div>
          </div>

          <div class="rosq-card">
            <div class="rosq-head"><span class="rosq-title">串口终端（ttyd）</span></div>
            <div class="rosq-form">
              ${check('启用 ttyd', 'TTYD_ENABLED')}
              ${field('监听地址', 'TTYD_BIND')}
              ${field('端口', 'TTYD_PORT', 'number')}
              ${field('访问凭据 用户名:密码（非 127.0.0.1 必填）', 'TTYD_CREDENTIAL')}
              ${field('RouterOS 用户名', 'ROS_USER')}
              ${field('RouterOS 密码（维护写盘用）', 'ROS_PASSWORD')}
            </div>
            <div class="rosq-dim" style="margin-top:6px">监听 <code>127.0.0.1</code> 时只有设备本机能连，浏览器打不开；改成 <code>0.0.0.0</code> 必须同时填访问凭据，否则后端拒绝启动。安装时会自动生成一组随机凭据。</div>
            <div class="rosq-actions">
              <button id="rosq_ttyd_open">打开终端</button>
              <button id="rosq_ttyd_restart">重启 ttyd</button>
              <button id="rosq_ttyd_stop">停止 ttyd</button>
            </div>
          </div>

          <div class="rosq-card">
            <div class="rosq-actions">
              <button id="rosq_save">保存（下次启动生效）</button>
              <button id="rosq_save_restart">保存并重启</button>
              <button id="rosq_uninstall">卸载</button>
            </div>
            <div class="rosq-credit">
              by <a href="https://github.com/enceka" target="_blank" rel="noopener noreferrer">Enceka</a>
              <span class="rosq-dim">· 管理脚本 v${MANAGER_VERSION}</span>
            </div>
          </div>
        </div>
      </div>`,
    });

    el.querySelector('#rosq_help').onclick = guard(showHelp, '帮助');
    el.querySelector('#rosq_toggle').onclick = guard(toggleVm, '启动/停止');
    el.querySelector('#rosq_restart').onclick = guard(() => action('restart', '正在重启…'), '重启');
    el.querySelector('#rosq_preflight').onclick = guard(() => action('preflight', '正在预检…'), '预检');
    el.querySelector('#rosq_logs').onclick = guard(showLogs, '查看日志');
    el.querySelector('#rosq_boot').onclick = guard(toggleBoot, '开机自启');
    el.querySelector('#rosq_takeover').onclick = guard(toggleTakeover, '接管 UFI 流量');
    el.querySelector('#rosq_sync').onclick = guard(syncNetworkNow, '同步网络配置');
    el.querySelector('#rosq_install').onclick = guard(() => installFromPackage(el.querySelector('#rosq_package_url').value.trim(), false), '在线安装');
    el.querySelector('#rosq_install_local').onclick = guard(pickAndInstallLocal, '本地安装');
    el.querySelector('#rosq_import_disk').onclick = guard(importDiskImage, '导入 CHR 镜像');
    el.querySelector('#rosq_update_script').onclick = guard(async () => {
      setBusy(true, '正在更新脚本…');
      try {
        const version = await deployManager();
        toast(`管理脚本已更新到 ${version}`, true);
      } catch (e) {
        toast(String(e?.message || e), false);
      } finally {
        setBusy(false);
        await refresh();
      }
    }, '更新脚本');
    el.querySelector('#rosq_add_forward').onclick = guard(() => {
      state.forwards.push({ enabled: true, name: `svc${state.forwards.length + 1}`, proto: 'tcp', bind: '0.0.0.0', host: '8291', guest: '8291' });
      renderForwards();
    }, '新增映射');
    el.querySelector('#rosq_usb_refresh').onclick = guard(refreshUsb, '刷新 USB');
    el.querySelector('#rosq_expand_disk').onclick = guard(expandDisk, '扩容磁盘');
    el.querySelector('#rosq_reclaim_disk').onclick = guard(reclaimDisk, '回收空间');
    el.querySelector('#rosq_backup').onclick = guard(createBackup, '备份');
    el.querySelector('#rosq_restore').onclick = guard(openBackupManager, '备份管理');
    el.querySelector('#rosq_ttyd_open').onclick = guard(openTtyd, '打开终端');
    el.querySelector('#rosq_ttyd_restart').onclick = guard(() => action('ttyd-restart', '正在重启 ttyd…'), '重启 ttyd');
    el.querySelector('#rosq_ttyd_stop').onclick = guard(() => action('ttyd-stop', '正在停止 ttyd…'), '停止 ttyd');
    el.querySelector('#rosq_save').onclick = guard(() => save(false), '保存');
    el.querySelector('#rosq_save_restart').onclick = guard(() => save(true), '保存并重启');
    el.querySelector('#rosq_uninstall').onclick = guard(uninstall, '卸载');
    el.querySelector('[data-key="STANDALONE"]').onchange = () => {
      state.config.STANDALONE = el.querySelector('[data-key="STANDALONE"]').value;
      renderForm();
    };

    showModal(id);
    if (!validIPv4(state.ufiIp)) toast('无法从 UFI_DATA.lan_ipaddr 读取有效地址，安装前请先确认 UFI 后台地址', false, 7000);
    await refresh();
    await refreshUsb();
    if (state.installed && state.managerVersion && state.managerVersion < MANAGER_VERSION) {
      if (await confirmAsk('rosq_mgr_update', '管理脚本可更新',
        `设备上的脚本版本 ${state.managerVersion}，插件内置 ${MANAGER_VERSION}。是否现在更新？`, '更新', 0)) {
        try {
          await deployManager();
          toast('管理脚本已更新', true);
          await refresh();
        } catch (e) {
          toast(String(e?.message || e), false);
        }
      }
    }
  };

  while (!document.querySelector('.actions-buttons')) await new Promise((resolve) => setTimeout(resolve, 120));
  const mainButton = document.createElement('button');
  mainButton.textContent = TITLE;
  mainButton.onclick = async () => {
    try {
      const r = await runRoot('whoami');
      if (!r.ok || !r.text.includes('root')) return createToast('请先开启 UFI-TOOLS 高级功能', 'red');
      await openModal();
    } catch (e) {
      console.error(`[${TITLE}] openModal`, e);
      createToast(`插件打开失败：${e?.message || e}`, 'red', 9000);
    }
  };
  document.querySelector('.actions-buttons')?.appendChild(mainButton);
})();
//</script>
