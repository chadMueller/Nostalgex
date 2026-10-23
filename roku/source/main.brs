' A deep link (source/guide/DeepLink.brs) comes in the launch args, or later
' as an roInput event; either way it goes to the scene to tune.
'
' The app's memory limit is logged at launch, and the OS's memory warnings
' (the app near its limit, the device low) as they come, which the Channel
' Store's static analysis asks a channel to listen for. They show in the
' console beside the build's own memory lines; nothing is freed on them yet.
sub Main(args = invalid as Dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)
    scene = screen.CreateScene("MainScene")
    screen.Show()
    link = NxDeepLinkFrom(args)
    if link <> invalid then scene.deepLink = link
    input = CreateObject("roInput")
    input.SetMessagePort(port)
    mem = CreateObject("roAppMemoryMonitor")
    mem.SetMessagePort(port)
    mem.EnableMemoryWarningEvent(true)
    print "app: memory limit "; FormatJson(mem.GetChannelMemoryLimit())
    device = CreateObject("roDeviceInfo")
    device.SetMessagePort(port)
    device.EnableLowGeneralMemoryEvent(true)
    ' What the server stream is sized to (NxMaxWidthFor), and whether this
    ' display takes HDR: a re-encode keeps the file's HDR tags on 8-bit video.
    print "app: video mode "; device.GetVideoMode(); ", display "; FormatJson(device.GetDisplayProperties())
    while true
        msg = Wait(0, port)
        if type(msg) = "roSGScreenEvent" and msg.IsScreenClosed() then return
        if type(msg) = "roInputEvent" and msg.IsInput() then
            link = NxDeepLinkFrom(msg.GetInfo())
            if link <> invalid then scene.deepLink = link
        end if
        ' roDeviceInfo also sends the TV's power and mute changes here; only
        ' one with a memory level is a memory notice.
        notice = type(msg) = "roAppMemoryNotificationEvent"
        if type(msg) = "roDeviceInfoEvent" then notice = msg.GetInfo().DoesExist("generalMemoryLevel")
        if notice then print "app: memory notice ("; type(msg); ") "; FormatJson(msg.GetInfo()); "; "; mem.GetMemoryLimitPercent(); "% of the limit"
    end while
end sub
