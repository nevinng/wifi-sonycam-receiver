# Introduction

I am using a Sony A7III camera as my daily camera. Normally I just take out the SD card and put it into my Mac's card reader or just connect them via the USB cable. Since the camera supports WiFi transfer, I thought why not give it a try? Unfortunately the official app is no longer maintained and doesn't work in macOS Golden Gate (v27).

So here comes the little app that receives photos (JPEG and RAW, no movies) from a Sony A7III camera while it is joined to the same Wi-Fi router as the Mac.

The camera menu for this is **Send to Computer**. The body opens a PTP/IP session on port 15740, and the app copies JPEG and RAW files into `~/Pictures/Sony A7`. Files already saved at the same size are skipped. Movies stay on the card.


## Compile

You need macOS 13 or later and the Swift toolchain from Xcode or the Xcode Command Line Tools.

In this directory, run:

```sh
./build.sh
```

The script runs `swift build -c release --product SonyReceive`, copies that executable into `Photo WiFi Receiver.app`, and ad-hoc signs the bundle. Open `Photo WiFi Receiver.app`. If the app is already running, quit it first. A running copy keeps the old program until you open the new one.


## Use

1. Build it with `./build.sh`, then open `Photo WiFi Receiver.app`.
2. The camera needs to be paired with the Mac first before we can transfer the photos wirelessly. So, for the first time, press **Set this Mac** and plug the camera in with USB and set to Auto/Mass Storage mode. The port could be locked fighting in bringing up the SD drive, etc. and the Mac ID cannot be set. If the port is busy, re-plug the camera until the app able to catch the window to do the setup.
3. To transfer, leave the camera joined to your router.
4. In the app, press **Receive photos**.
5. On the camera choose Menu → Network → Send to Computer, then select which memory card, and leave that screen up.

If the router’s client list shows the camera’s address, type it into Camera IP. Otherwise the app searches the local network.

**Send to Computer** can turn the camera off when the copy finishes. That is the camera’s own behavior for this menu.



## References

This app does not link these projects. The Sony handshake and the USB host record follow what they published.

- [libgphoto2](https://github.com/gphoto/libgphoto2) — `ptp_sony_9280` and `ptp_sony_9281` in `camlibs/ptp2/ptp.c`. [Issue 16](https://github.com/gphoto/libgphoto2/issues/16) records the four packets that switch the camera to Sending, and the command that powers it off after the save.
- [Sony-PMCA-RE](https://github.com/ma1co/Sony-PMCA-RE) — `pmca/usb/sony.py` names the ExtBackupCommunicator commands. Command 2 asks the camera to send photos. Command 5 is the power-off after the save.
- [sony-pm-alt](https://github.com/falk0069/sony-pm-alt) — how Send to Computer announces itself, and the computer identity of eight zero bytes, `FF FF`, then the Mac address. [`sony-guid-setter.c`](https://github.com/falk0069/sony-pm-alt/blob/master/sony-guid-setter.c), from Clemens Fruhwirth, is the USB write that **Set this Mac** follows.

## Disclaimer

[MIT](LICENSE). You may use, study, and change this project. It is provided as is, with no warranty, and the authors bear no liability for damage, data loss, or any other consequence of building or using it.

The packet layouts and command numbers in References come from other projects. This repository does not include their source. [libgphoto2](https://github.com/gphoto/libgphoto2) and [`sony-guid-setter.c`](https://github.com/falk0069/sony-pm-alt/blob/master/sony-guid-setter.c) are LGPL-2.1. [Sony-PMCA-RE](https://github.com/ma1co/Sony-PMCA-RE) is MIT.

Sony and α are trademarks of Sony Group Corporation. This project is not affiliated with or endorsed by Sony.
