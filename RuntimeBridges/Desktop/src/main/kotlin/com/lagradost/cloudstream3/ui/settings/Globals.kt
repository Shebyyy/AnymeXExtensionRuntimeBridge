package com.lagradost.cloudstream3.ui.settings

object Globals {
    var beneneCount = 0

    const val PHONE: Int = 0b001
    const val TV: Int = 0b010
    const val EMULATOR: Int = 0b100

    private var layoutId: Int = PHONE

    fun updateTv() {
        layoutId = PHONE
    }

    fun isLandscape(): Boolean = false

    fun isLayout(flags: Int): Boolean {
        return (layoutId and flags) != 0
    }
}