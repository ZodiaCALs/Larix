# Larix

Larix is a native macOS mixer for individual applications. Open **build/Larix.app**, select an app in the sidebar, and adjust its volume, mute, five-band equalizer, or audio devices. Click the waveform in the menu bar to adjust several apps from one list. Click an app’s name to reveal its EQ presets and output selector. Closing the mixer hides Larix from the Dock and keeps audio processing and the menu bar panel running. Choose **Open mixer** to bring the window and Dock icon back. Quit Larix to release all playback taps.

Requires macOS 14.2 or later. The universal app runs on Apple silicon and Intel.

Use the paint palette beside **Larix** in the mixer or menu bar panel to change appearance. Choose **System**, **Light**, or **Dark**, select a **Forest**, **Ocean**, or **Iris** palette, and pick **Glass** or **Solid** surfaces. Both views share your choices and remember them when you quit. Glass uses Liquid Glass on macOS 26 and later and translucent materials on earlier releases. The macOS **Reduce transparency** setting also enables solid surfaces.

## Playback

1. Play audio in an app and select it in Larix. macOS may ask for system audio recording permission on the first playback adjustment. Allow Larix in **System Settings → Privacy & Security → Screen & System Audio Recording**. Follow any macOS relaunch prompt.
2. Drag the volume slider or click the speaker to mute. Drag an EQ point vertically, click a frequency readout for a precise slider, or choose a preset. The EQ switch bypasses the five filters while retaining their values. Bands outside the output’s frequency range are dimmed and become available again when the output supports them.
3. Choose **App output** to follow the app’s reported destination, **System default** to follow the Mac’s current output, or a device by name. A disconnected device produces a routing message. Larix retries when the device returns.
4. Use the app header’s **Playback options → Reset playback to defaults** to return to the app’s own playback.

Larix saves settings per application and reapplies them as its Core Audio clients appear. At unity volume with flat EQ and app-selected output, playback flows directly from the app. Active processing mixes the app down to stereo and sends it to one destination. For apps with multiple simultaneous destinations, **App output** prefers the system device when it is among them. Copy-protected audio and clients macOS excludes from process taps can have limited playback support.

## Microphones

Choose a microphone under **Audio routing**. Larix creates a persistent Core Audio aggregate device named **Larix · App Name**. Select that device once in the target app’s microphone settings. Subsequent microphone changes in Larix update the same endpoint. Apps that only accept the system microphone cannot select a per-app endpoint. Microphone access is controlled by the receiving app’s usual macOS permission.

To remove the endpoint, return the target app to its usual microphone and choose **Use app settings** in Larix. Input endpoints can also be inspected in Audio MIDI Setup.

## Build

Install Xcode 26 or later, or Command Line Tools with the macOS 26 or later SDK. From the Larix directory, run:

```sh
./build.sh
open build/Larix.app
```

The build runs the signal-processing tests, generates the icon, compiles both architectures, and verifies the signed bundle. The default signature is ad hoc for local use. Set `SIGN_IDENTITY` to use your own signing identity, or `ARCHS=arm64` to build only for Apple silicon.

The playback path uses public Core Audio process taps, a private aggregate capture device, and a HAL output audio unit. A bounded stereo buffer bridges device clocks. Five peaking filters process the output, and the EQ graph uses the same coefficients. Processing runs locally in memory.
