package dev.conest.conest

import android.content.Intent
import android.test.AndroidTestCase

/** Requires an Android device; the production picker remains file_picker. */
@Suppress("DEPRECATION")
class FilePickerVisibilityTest : AndroidTestCase() {
    fun testDocumentPickerKeepsSelectionAndExposesStorageRoots() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        FilePickerVisibility.prepare(intent)
        assertTrue(intent.getBooleanExtra("android.provider.extra.SHOW_ADVANCED", false))
        assertTrue(intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
        assertEquals("*/*", intent.type)
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, intent.action)
    }

    fun testGalleryAndUnrelatedIntentsAreUnchanged() {
        for (action in listOf(Intent.ACTION_GET_CONTENT, Intent.ACTION_VIEW)) {
            val intent = Intent(action).apply { type = "image/*" }
            FilePickerVisibility.prepare(intent)
            assertFalse(intent.hasExtra("android.provider.extra.SHOW_ADVANCED"))
        }
    }
}
