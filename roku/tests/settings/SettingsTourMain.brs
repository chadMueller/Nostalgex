' Settings tour entry point (scripts/deploy.sh --settings-tour): SettingsView on
' its own, over made-up packages, franchises and collections, for looking at
' the channel rows on a TV and walking them with a remote. No server, no
' library and no video, so a TV whose display refuses the picture (an HDCP
' error over every screen of the real app) can still be screenshotted.
'
' Only ever in the test data space (deploy.sh sets NX_TEST_DATA=1): the tour
' saves package and collection choices to make its rows, and the scene stops at
' once if its registry is the real app's.
'
' Launch arguments (ECP: POST /launch/dev?state=off):
'   state=on        (default) FRANCHISES on: the classics, two found franchises
'                   and two franchise collections in one list
'   state=off       FRANCHISES off: only the franchise collections are listed
'   state=empty     FRANCHISES on, nothing to list yet
'   state=folded    every collection the server has is a franchise
'   state=overcap   the shared block is full: its one note
sub Main(args = invalid as Dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)
    scene = screen.CreateScene("SettingsTourScene")
    screen.Show()
    if type(args) = "roAssociativeArray" then scene.args = args else scene.args = {}
    print "TOUR READY"
    while true
        msg = Wait(0, port)
        if type(msg) = "roSGScreenEvent" and msg.IsScreenClosed() then return
    end while
end sub
