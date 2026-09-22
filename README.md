# Poddle Helper

Poddle Helper is a small, open-source Mac app. It lets [Poddle](https://poddleball.com) use one of your AirPods as your paddle.

Most people do not need it. You can play Poddle with your phone as the paddle, and that needs nothing installed. This app is only for playing with an AirPod on a Mac.

## Download

Download: https://poddleball.com/download/Poddle-Helper.zip

Or from the Releases page: https://github.com/danielrltan/poddle-helper/releases/latest/download/Poddle-Helper.zip

Unzip it, then move **Poddle Helper** to your Applications folder if you like.

## Opening it the first time

The app is not signed with an Apple Developer ID yet. That costs money and takes time, and this is a small side project. So macOS does not know who made it, and it will warn you the first time. After you allow it once, it opens normally.

**macOS 15 (Sequoia) and later**

1. Double-click Poddle Helper. macOS says Apple could not verify it is free of malware. Click **Done**, not Move to Trash (if you already trashed it, download it again).
2. Open **System Settings > Privacy & Security**.
3. Scroll down. Next to "Poddle Helper was blocked", click **Open Anyway**.
4. Enter your password, then click **Open Anyway** again.

**macOS 14 (Sonoma)**

1. Right-click (or Control-click) Poddle Helper and choose **Open**.
2. Click **Open** in the dialog.

The steps for macOS 15 also work on 14.

If you would rather not trust a download, you can read the code and build the app yourself. See [Build it yourself](#build-it-yourself).

## Using it

1. Open Poddle Helper. It adds an AirPod icon to the menu bar. It has no window and no Dock icon.
2. Open [poddleball.com](https://poddleball.com) and choose to play with an AirPod.
3. The first time, macOS asks to allow Motion & Fitness access. Click **Allow**.
4. Take one AirPod out of your ear and hold it. That is your paddle.

Click the menu bar icon to see what is happening, for example "Waiting for Poddle to connect" or "Streaming from left AirPod".

## What it reads

Only headphone motion, from Apple's CoreMotion headphone motion API:

- orientation (which way the AirPod is pointing)
- rotation rate (how fast it is turning)
- acceleration (how fast it is moving)
- which bud it is (left or right)

It does **not** read audio, the microphone, your location, contacts, files, or anything else. It has no account and no sign-in.

It only reads motion while a Poddle page is connected to it. When you close the page, it stops.

## Where it sends it

Only to web pages on your own Mac:

- It listens on `127.0.0.1:8787` (and `[::1]:8787`). Those addresses only exist inside your Mac. Other computers on your network, or on the internet, cannot reach it.
- It only answers web pages from Poddle: `https://poddleball.com`, `https://www.poddleball.com` and `https://poddle.fly.dev`. It also answers `http://localhost`, for people working on Poddle itself. Any other website is refused. Browsers tell the app which site a page comes from (the Origin header), and websites cannot fake it.
- The app itself never connects to the internet. There is no analytics, no update check, and no tracking. "Open Poddle" and "About / View source" in the menu open pages in your browser.

All of this is in one file: [`Sources/main.swift`](Sources/main.swift). It is under 400 lines.

## Permissions it asks for

- **Motion & Fitness.** This is what macOS calls headphone motion access. You can turn it off any time in System Settings > Privacy & Security > Motion & Fitness.
- In Chrome, poddleball.com may ask to "access other apps and services on this device" or to connect to devices on your local network. That is the Poddle page reaching this app on your Mac. The app itself does not ask for network access.

## Requirements

- macOS 14 or later, on Apple silicon or Intel.
- AirPods Pro, AirPods 3, AirPods 4 or AirPods Max, connected to the Mac as the sound output.
- Automatic Ear Detection turned off, so motion keeps flowing when the AirPod is out of your ear. Go to System Settings > Bluetooth, click the ⓘ next to your AirPods, and turn off Automatic Ear Detection.

## Uninstall

Click the menu bar icon and choose **Quit Poddle Helper**. Then drag the app to the Trash. It leaves nothing else behind.

## Build it yourself

You need Apple's command line tools (`xcode-select --install`). No Xcode project and no other dependencies.

```
git clone https://github.com/danielrltan/poddle-helper
cd poddle-helper
./build.sh
open "build/Poddle Helper.app"
```

`build.sh` compiles `Sources/main.swift` for Apple silicon and Intel, puts the app together, signs it locally (ad hoc), and zips it to `dist/Poddle-Helper.zip`.

For testing without AirPods, `PODDLE_HELPER_FAKE=1` sends made-up motion, and `PODDLE_HELPER_PORT` changes the port:

```
PODDLE_HELPER_PORT=8797 PODDLE_HELPER_FAKE=1 "build/Poddle Helper.app/Contents/MacOS/PoddleHelper"
```

## What the page receives

Each WebSocket message is one JSON object:

```
{"t": 12.34, "loc": 1, "q": [x, y, z, w], "r": [x, y, z], "a": [x, y, z]}
```

- `t`: time in seconds
- `loc`: which bud, 1 is left, 2 is right, 0 is unknown
- `q`: orientation as a quaternion
- `r`: rotation rate in radians per second
- `a`: acceleration in g, without gravity

## License

MIT. See [LICENSE](LICENSE).
