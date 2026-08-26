## Install the desktop app (Linux)

Voyager on Linux is distributed as an [AppImage](https://appimage.org/). Download the app from the [website](https://voyager.swmansion.com/download).

### Run directly

```sh
chmod +x Voyager-*-AppImage
./Voyager-*-AppImage
```

### Integrate into your app menu (recommended)

Use [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) to install the AppImage so it appears in your application launcher, with icons and desktop integration handled for you.

1. Install Gear Lever from Flathub:

   ```sh
   flatpak install flathub it.mijorus.gearlever
   ```

2. Open Gear Lever, drag in the Voyager AppImage (or use **+** to pick the file).
3. Confirm the source, then choose **Move to the app menu**.

Step-by-step walkthrough: [How To Easily Manage AppImages With Gear Lever In Linux](https://ostechnix.com/manage-appimages-with-gear-lever/) (OSTechNix).
