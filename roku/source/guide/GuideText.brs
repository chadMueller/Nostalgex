' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' GUIDE TEXT SIZE (I-060), a Roku-only display choice in Settings: NORMAL, the
' Apple TV's sizes, or LARGE, for a couch further from the screen. Built in,
' two sizes and no choice of fonts. It sizes what the grid draws: the time
' header, the CHANNEL heading, each row's number and name, and the program
' titles. The panel above the grid stays as it is, its text is already laid out
' to fill 555 px.
'
' The saved choice is "large" under the guide's registry section; anything
' else, and a TV that never chose, is NORMAL.

function NxGuideTextLarge() as Boolean
    return NxGuideTextFrom(NxRegSection("guide").Read("textSize"))
end function

' From the saved value: only "large" is LARGE.
function NxGuideTextFrom(saved as String) as Boolean
    return saved = "large"
end function

sub NxSaveGuideTextLarge(on as Boolean)
    reg = NxRegSection("guide")
    if on then reg.Write("textSize", "large") else reg.Write("textSize", "normal")
    reg.Flush()
end sub

' The grid's type sizes and where each line sits, the row 80 px tall and the
' header 60. NORMAL is what the guide has always drawn. A line's top is the
' middle of its row less half its height (about 1.3 times its size).
'   slot, slotY, slotH: a time label, and the rule beside it
'   title, titleY: a program's title
'   num, numW, numY: a channel's number, its width (three digits) and top
'   name, nameY, nameGap: the name, its top, and its start from the number's
'   head, headY: the CHANNEL heading
' LARGE grows the program titles most, as the channel column is only 220 px
' wide: its number and name grow less, and the name keeps what room is left.
function NxGuideTextSizes(large as Boolean) as Object
    if large then
        return {
            slot: 26, slotY: 13, slotH: 34,
            title: 26, titleY: 23,
            num: 24, numW: 44, numY: 24,
            name: 20, nameY: 27, nameGap: 52,
            head: 22, headY: 16
        }
    end if
    return {
        slot: 20, slotY: 17, slotH: 26,
        title: 20, titleY: 27,
        num: 20, numW: 36, numY: 27,
        name: 18, nameY: 29, nameGap: 44,
        head: 18, headY: 18
    }
end function
