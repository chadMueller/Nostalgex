' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' ABOUT > LINKS, the Apple TV's AboutLinks.all (Views/Settings/AboutLinks.swift):
' Discord, the website, the web tuner, Roku and GitHub, in that order. A TV has
' no browser, so each is an address to read and open on a phone or computer,
' shown without https://. This is the one list: SettingsView builds a row for
' each, so an address changes in one place. `id` is also the row's `linkId`.

function NxAboutLinks() as Object
    return [
        { id: "discord", title: "DISCORD", subtitle: "Chat with other viewers and get help. Open it on a phone or computer.", address: "discord.gg/FgnZcr5bDT" },
        { id: "website", title: "WEBSITE", subtitle: "The Nostalgex website. Open it on a phone or computer.", address: "nostalgex.app" },
        { id: "web_tuner", title: "WEB TUNER", subtitle: "Nostalgex in a web browser. Open it on a phone or computer.", address: "nostalgex.app/web-tuner" },
        { id: "roku", title: "ROKU", subtitle: "Add it from the Roku Channel Store. Channel code: NOSTALGEX.", address: "my.roku.com/account/add/NOSTALGEX" },
        { id: "github", title: "GITHUB", subtitle: "Source code and issues. Open it on a phone or computer.", address: "github.com/chadMueller/Nostalgex" }
    ]
end function

' The link whose id is `linkId`, or invalid.
function NxAboutLink(linkId as Dynamic) as Dynamic
    for each link in NxAboutLinks()
        if link.id = NxToStr(linkId) then return link
    end for
    return invalid
end function
