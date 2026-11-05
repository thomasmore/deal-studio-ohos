/** Starts copying packets between the VPN's tun fd and the relay at 127.0.0.1:port; reconnects on its own. */
export const usbnetStart: (tunFd: number, port: number) => void
export const usbnetStop: () => void
/** 'off', 'waiting for the computer ...' or 'connected, up N KB, down N KB'. */
export const usbnetStatus: () => string
