on run arguments
  if (count of arguments) is not 1 then error "Expected the mounted volume name"
  set volumeName to item 1 of arguments

  tell application "Finder"
    set targetDisk to disk (volumeName as text)
    tell targetDisk
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {100, 100, 820, 540}

      set viewOptions to icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 112
      set text size of viewOptions to 13
      set background picture of viewOptions to file ".background:installer-background.png"

      set position of item "CodexDone.app" of container window to {180, 235}
      set position of item "Applications" of container window to {540, 235}

      update without registering applications
      delay 2
      close container window
    end tell
  end tell
end run
