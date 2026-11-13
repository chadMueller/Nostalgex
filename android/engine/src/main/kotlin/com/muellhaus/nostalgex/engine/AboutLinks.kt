package com.muellhaus.nostalgex.engine

/**
 * One line under ABOUT > LINKS: a name, what it is, and the address to read. As the Apple
 * TV 1.0.32's `AboutLink` (Views/Settings/AboutLinks.swift): a TV has no web browser, so an
 * address is text to read and open on a phone or computer, never a button that opens anything.
 * The addresses are the ones the site, the README and the Roku listing already publish.
 */
data class AboutLink(
    /** Also the Settings row id (`about_<id>`). */
    val id: String,
    val title: String,
    val subtitle: String,
    /** What is shown, without `https://`. */
    val address: String,
) {
    val rowId: String get() = "about_$id"
}

object AboutLinks {
    val discord = AboutLink("discord", "DISCORD", "Chat with other viewers and get help. Open it on a phone or computer.", "discord.gg/FgnZcr5bDT")
    val website = AboutLink("website", "WEBSITE", "The Nostalgex website. Open it on a phone or computer.", "nostalgex.app")
    val webTuner = AboutLink("web_tuner", "WEB TUNER", "Nostalgex in a web browser. Open it on a phone or computer.", "nostalgex.app/web-tuner")
    val roku = AboutLink("roku", "ROKU", "Add it from the Roku Channel Store. Channel code: NOSTALGEX.", "my.roku.com/account/add/NOSTALGEX")
    val github = AboutLink("github", "GITHUB", "Source code and issues. Open it on a phone or computer.", "github.com/chadMueller/Nostalgex")

    /** In the order they are listed. */
    val all: List<AboutLink> = listOf(discord, website, webTuner, roku, github)
}
