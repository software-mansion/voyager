## Install the desktop app (Linux)

Voyager on Linux is distributed as a `.deb` package and an [AppImage](https://appimage.org/). Download the app from the [website](https://voyager.swmansion.com/download).

### Debian and Ubuntu (recommended)

```sh
sudo apt install ./Voyager-linux-amd64.deb
```

Voyager appears in your application launcher and updates itself in place.

### Other distributions: AppImage

```sh
chmod +x Voyager-linux-amd64.AppImage
./Voyager-linux-amd64.AppImage
```

The AppImage needs FUSE 2. On distributions that no longer ship it, install `libfuse2` (`libfuse2t64` on Ubuntu 24.04+) or use the `.deb` package.

#### Integrate into your app menu

Use [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) to install the AppImage so it appears in your application launcher, with icons and desktop integration handled for you.

1. Install Gear Lever from Flathub:

   ```sh
   flatpak install flathub it.mijorus.gearlever
   ```

2. Open Gear Lever, drag in the Voyager AppImage (or use **+** to pick the file).
3. Confirm the source, then choose **Move to the app menu**.

Step-by-step walkthrough: [How To Easily Manage AppImages With Gear Lever In Linux](https://ostechnix.com/manage-appimages-with-gear-lever/) (OSTechNix).
