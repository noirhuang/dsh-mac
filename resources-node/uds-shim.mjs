// UDS shim：把 dsh web 的 TCP listen 重定向到 Unix Domain Socket。
// 用法：DSH_SOCKET_PATH=/path/to.sock node --import uds-shim.mjs <dsh bin> web ...
// 不修改 dsh 源码，从源码更新后依然生效。
import net from 'node:net'
import fs from 'node:fs'

const SOCKET_PATH = process.env.DSH_SOCKET_PATH
if (SOCKET_PATH) {
  const statIno = () => { try { return fs.statSync(SOCKET_PATH).ino } catch { return null } }
  // 归属校验：记录本次创建的 socket inode；退出清理只删除仍属于自己的文件，
  // 防止多实例并发时误删他人（仍被存活进程使用）的 socket。
  let ownIno = null
  const cleanup = () => {
    try {
      if (ownIno !== null && statIno() === ownIno) fs.unlinkSync(SOCKET_PATH)
    } catch { /* ignore */ }
  }
  process.once('exit', cleanup)
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.once(signal, () => { cleanup(); process.exit(0) })
  }

  const origListen = net.Server.prototype.listen
  net.Server.prototype.listen = function (...args) {
    // 仅拦截 TCP 形态（首个参数是数字端口）；UDS/已有 path 调用原样放行
    if (typeof args[0] === 'number' && args[0] > 0) {
      const callback = args.find(a => typeof a === 'function')
      try { fs.unlinkSync(SOCKET_PATH) } catch { /* 首次启动无残留 */ }
      const wrapped = () => {
        ownIno = statIno()
        try { fs.chmodSync(SOCKET_PATH, 0o600) } catch { /* ignore */ }
        callback?.()
      }
      return origListen.call(this, SOCKET_PATH, wrapped)
    }
    return origListen.apply(this, args)
  }

  // address() 兼容：UDS 下返回 { address: path }；伪造 AddressInfo 形状，
  // 让上层读取 .port/.address 不崩（值为标记字符串）。
  const origAddress = net.Server.prototype.address
  net.Server.prototype.address = function () {
    const addr = origAddress.call(this)
    if (addr !== null && typeof addr === 'string') {
      return { address: '127.0.0.1', family: 'IPv4', port: 0 }
    }
    return addr
  }
}
