package com.illunis.illunis_client

import android.app.Activity
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView

/**
 * Health Connect privacy rationale. Shown from the Health Connect permission
 * screen: `androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE` up to Android 13
 * and, through the ViewPermissionUsageActivity alias, `VIEW_PERMISSION_USAGE`
 * with category HEALTH_PERMISSIONS on Android 14+. Plain text, no data access.
 */
class HealthRationaleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (24 * resources.displayMetrics.density).toInt()
        val text = TextView(this).apply {
            setPadding(pad, pad, pad, pad)
            textSize = 16f
            text = RATIONALE
        }
        setContentView(ScrollView(this).apply { addView(text) })
    }

    private companion object {
        const val RATIONALE =
            "Illunis reads your sleep sessions, steps and heart rate from Health Connect " +
                "to describe patterns over the last three weeks.\n\n" +
                "It only reads; it never writes or deletes health data. The readings stay on " +
                "this phone. Daily totals (minutes asleep, steps, lowest heart rate) are sent to " +
                "the Illunis server only when you ask for the three-week analysis, and the server " +
                "does not keep them.\n\n" +
                "Illunis gives general information, not medical advice.\n\n" +
                "You can remove access at any time in Health Connect settings."
    }
}
