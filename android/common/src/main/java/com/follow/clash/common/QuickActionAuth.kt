package com.follow.clash.common

import java.util.UUID

private const val PREF_NAME = "quick_action_auth"
private const val KEY_TOKEN = "token"

object QuickActionAuth {
    const val EXTRA_TOKEN = "quick_action_token"

    private fun token(): String {
        val preferences = GlobalState.application.getSharedPreferences(PREF_NAME, 0)
        val existed = preferences.getString(KEY_TOKEN, null)
        if (!existed.isNullOrBlank()) {
            return existed
        }
        val next = UUID.randomUUID().toString().replace("-", "")
        preferences.edit().putString(KEY_TOKEN, next).apply()
        return next
    }

    fun attach(intent: android.content.Intent): android.content.Intent {
        intent.putExtra(EXTRA_TOKEN, token())
        return intent
    }

    fun verify(intent: android.content.Intent?): Boolean {
        if (intent == null) return false
        val inToken = intent.getStringExtra(EXTRA_TOKEN)
        if (inToken.isNullOrBlank()) return false
        return inToken == token()
    }
}
