The relay half of gnirehtet 2.5.1 (Apache 2.0, LICENSE here), used by
`usb-net.sh`. Only `gnirehtet relay` is used: it listens on 127.0.0.1:31416 (the
phone reaches it as its own 127.0.0.1:28416, through `hdc rport`) and
opens the real connections for the phone. The phone half is ours
(`UsbNetAbility.ets` + `napi_usbnet.cpp`), since gnirehtet's client is Android-only.

From https://github.com/Genymobile/gnirehtet/releases/download/v2.5.1/gnirehtet-java-v2.5.1.zip
sha256 of gnirehtet.jar: 4a59a5dad69f08c0a86e0273a83a0a25fe2f8bd0a3f625887ee98ef46b9aafb8
That zip's sha256 (816748078fa6a304600a294a13338a06ac778bcc0e57b62d88328c7968ad2d3a)
matches the release's own
https://github.com/Genymobile/gnirehtet/releases/download/v2.5.1/SHA256SUMS.txt
