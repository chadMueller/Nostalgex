' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' See LibrarySectionsTask.xml. Never fails the sign-in: any trouble gives an
' empty list, and the first scan starts without the picker.

sub init()
    m.top.functionName = "run"
end sub

sub run()
    reg = NxPlexRegistry()
    servers = ParseJson(reg.Read("servers"))
    out = []
    if type(servers) = "roArray" and servers.Count() > 0 then
        on = NxServersOn(servers, NxSavedServerChoices())
        if NxSignedInKind() = "plex" then NxPlexResolveSaved(servers, on)
        for i = 0 to servers.Count() - 1
            s = servers[i]
            if on[i] and NxToStr(s.uri) <> "" then
                kind = NxServerKind(s)
                if kind = "plex" then
                    err = { auth: false }
                    mc = NxPlexGetContainer(s, "/library/sections", err)
                    if mc <> invalid then out.Append(NxPlexSectionRefs(s, mc.Directory))
                else
                    userId = NxToStr(s.userId)
                    fetcher = NxMbFetcher(s)
                    plain = fetcher.getJSON(NxMbViewsPath(kind, userId, false))
                    all = fetcher.getJSON(NxMbViewsPath(kind, userId, true))
                    if all = invalid then all = plain
                    if all <> invalid then
                        hidden = {}
                        if plain <> invalid and kind <> "emby" then
                            shown = {}
                            for each v in NxList(plain.Items)
                                shown[NxToStr(v.Id)] = true
                            end for
                            for each v in NxList(all.Items)
                                if shown[NxToStr(v.Id)] <> true then hidden[NxToStr(v.Id)] = true
                            end for
                        end if
                        out.Append(NxMbSectionRefs(s, all.Items, hidden))
                    end if
                end if
            end if
        end for
    end if
    print "sections: "; out.Count(); " library sections listed on "; NxPlexRegistry().Read("kind")
    m.top.sections = out
    m.top.status = "done"
end sub
