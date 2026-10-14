package dev.conest.conest

import android.content.Intent

/** Exposes provider roots in the system file dialog; providers still decide
 * whether dot-folders are visible. This never changes gallery filtering. */
internal object FilePickerVisibility {
    fun prepare(intent: Intent) {
        if (intent.action == Intent.ACTION_OPEN_DOCUMENT &&
            intent.hasCategory(Intent.CATEGORY_OPENABLE)) {
            intent.putExtra("android.provider.extra.SHOW_ADVANCED", true)
        }
    }
}
