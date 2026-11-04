package com.illunis.illunis_client

import android.app.Activity
import android.content.Intent
import android.os.Build
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.request.AggregateGroupByPeriodRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.Period
import java.time.ZoneId

/**
 * MethodChannel `illunis/health`: Health Connect reads for the 21-day
 * analysis. Dart side: client/lib/health/health_port.dart.
 *
 * Methods:
 *  - `availability`       -> "available" | "not_installed" | "update_required" | "unsupported"
 *  - `hasPermissions`     -> Boolean (sleep, steps and heart rate all granted)
 *  - `requestPermissions` -> "granted" | "partial" | "denied"; opens the Health
 *                            Connect sheet (asked by voice first, in Dart)
 *  - `readDaily` {days}   -> {tz, days: [{day, sleep_minutes, steps, resting_hr}]}
 *                            for the last `days` local days (1..31), oldest first
 *
 * Per day: sleep_minutes is the time asleep (awake stages left out, overlapping
 * sessions from several apps merged) in sessions that END that day; steps is
 * Health Connect's deduplicated daily total; resting_hr is the lowest bpm of
 * the day (a stand-in until RestingHeartRateRecord is read). A value is null
 * when its permission is missing or there is no data.
 *
 * Error codes (no details, no record content): `not_available`, `busy`,
 * `not_granted`, `read_failed`, `internal`.
 */
class HealthChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val contract = PermissionController.createRequestPermissionResultContract()
    private var pendingPermission: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "availability" -> result.success(availability())
                "hasPermissions" -> withClient(result) { c ->
                    result.success(granted(c).containsAll(PERMISSIONS))
                }
                "requestPermissions" -> requestPermissions(result)
                "readDaily" -> {
                    val days = (call.argument<Int>("days") ?: DEFAULT_DAYS).coerceIn(1, MAX_DAYS)
                    withClient(result) { c -> result.success(readDaily(c, days)) }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("internal", "health call failed", null)
        }
    }

    private fun availability(): String =
        when (HealthConnectClient.getSdkStatus(activity)) {
            HealthConnectClient.SDK_AVAILABLE -> "available"
            HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> "update_required"
            else -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) "not_installed" else "unsupported"
        }

    /** Runs [block] with a client on the main scope; failures become fixed codes. */
    private fun withClient(result: MethodChannel.Result, block: suspend (HealthConnectClient) -> Unit) {
        if (HealthConnectClient.getSdkStatus(activity) != HealthConnectClient.SDK_AVAILABLE) {
            result.error("not_available", "Health Connect is not available", null)
            return
        }
        val client = HealthConnectClient.getOrCreate(activity)
        scope.launch {
            try {
                block(client)
            } catch (e: SecurityException) {
                result.error("not_granted", "permission missing", null)
            } catch (e: Exception) {
                result.error("read_failed", "health read failed", null)
            }
        }
    }

    private suspend fun granted(c: HealthConnectClient): Set<String> =
        c.permissionController.getGrantedPermissions()

    private fun requestPermissions(result: MethodChannel.Result) {
        if (pendingPermission != null) {
            result.error("busy", "a permission request is already open", null)
            return
        }
        withClient(result) { c ->
            val have = granted(c)
            if (have.containsAll(PERMISSIONS)) {
                result.success("granted")
                return@withClient
            }
            pendingPermission = result
            try {
                activity.startActivityForResult(contract.createIntent(activity, PERMISSIONS), REQUEST_CODE)
            } catch (e: Exception) {
                pendingPermission = null
                result.error("not_available", "permission sheet unavailable", null)
            }
        }
    }

    /** Forwarded from MainActivity.onActivityResult. Returns true if handled. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val r = pendingPermission ?: return true
        pendingPermission = null
        val fromSheet = try {
            contract.parseResult(resultCode, data)
        } catch (e: Exception) {
            emptySet()
        }
        // Ask again: the sheet reports only what changed in this request.
        scope.launch {
            val have = try {
                granted(HealthConnectClient.getOrCreate(activity))
            } catch (e: Exception) {
                fromSheet
            }
            r.success(
                when {
                    have.containsAll(PERMISSIONS) -> "granted"
                    have.any { it in PERMISSIONS } -> "partial"
                    else -> "denied"
                },
            )
        }
        return true
    }

    private suspend fun readDaily(c: HealthConnectClient, days: Int): Map<String, Any?> {
        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val first = today.minusDays((days - 1).toLong())
        val have = granted(c)
        val steps = HashMap<LocalDate, Long>()
        val minHr = HashMap<LocalDate, Long>()
        val metrics = buildSet {
            if (READ_STEPS in have) add(StepsRecord.COUNT_TOTAL)
            if (READ_HEART_RATE in have) add(HeartRateRecord.BPM_MIN)
        }
        if (metrics.isNotEmpty()) {
            val groups = c.aggregateGroupByPeriod(
                AggregateGroupByPeriodRequest(
                    metrics = metrics,
                    timeRangeFilter = TimeRangeFilter.between(first.atStartOfDay(), today.plusDays(1).atStartOfDay()),
                    timeRangeSlicer = Period.ofDays(1),
                ),
            )
            for (g in groups) {
                val day = g.startTime.toLocalDate()
                g.result[StepsRecord.COUNT_TOTAL]?.let { steps[day] = it }
                g.result[HeartRateRecord.BPM_MIN]?.let { minHr[day] = it }
            }
        }
        val sleep = if (READ_SLEEP in have) sleepMinutes(c, first, today, zone) else emptyMap()
        val out = ArrayList<Map<String, Any?>>()
        var d = first
        while (!d.isAfter(today)) {
            out.add(
                mapOf(
                    "day" to d.toString(),
                    "sleep_minutes" to sleep[d],
                    "steps" to steps[d],
                    "resting_hr" to minHr[d],
                ),
            )
            d = d.plusDays(1)
        }
        return mapOf("tz" to zone.id, "days" to out)
    }

    /** Minutes asleep per wake-up day, overlaps merged across sessions. */
    private suspend fun sleepMinutes(
        c: HealthConnectClient,
        first: LocalDate,
        last: LocalDate,
        zone: ZoneId,
    ): Map<LocalDate, Int> {
        // A night that ends on [first] starts the evening before.
        val from = first.minusDays(1).atStartOfDay(zone).toInstant()
        val to = last.plusDays(1).atStartOfDay(zone).toInstant()
        val intervals = HashMap<LocalDate, MutableList<Pair<Instant, Instant>>>()
        var token: String? = null
        var pages = 0
        do {
            val page = c.readRecords(
                ReadRecordsRequest(
                    recordType = SleepSessionRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(from, to),
                    pageToken = token,
                ),
            )
            for (s in page.records) {
                val day = s.endTime.atZone(zone).toLocalDate()
                if (day.isBefore(first) || day.isAfter(last)) continue
                val asleep = if (s.stages.isEmpty()) {
                    listOf(s.startTime to s.endTime)
                } else {
                    s.stages.filter { it.stage !in AWAKE_STAGES }.map { it.startTime to it.endTime }
                }
                intervals.getOrPut(day) { mutableListOf() }.addAll(asleep.filter { it.second.isAfter(it.first) })
            }
            token = page.pageToken
            pages++
        } while (!token.isNullOrEmpty() && pages < MAX_PAGES)
        return intervals.mapValues { (_, list) -> mergedMinutes(list).coerceAtMost(24 * 60) }
    }

    private fun mergedMinutes(list: List<Pair<Instant, Instant>>): Int {
        var total = 0L
        var curStart: Instant? = null
        var curEnd: Instant? = null
        for ((s, e) in list.sortedBy { it.first }) {
            val ce = curEnd
            if (ce == null || s.isAfter(ce)) {
                if (curStart != null && ce != null) total += ce.toEpochMilli() - curStart.toEpochMilli()
                curStart = s
                curEnd = e
            } else if (e.isAfter(ce)) {
                curEnd = e
            }
        }
        val cs = curStart
        val ce = curEnd
        if (cs != null && ce != null) total += ce.toEpochMilli() - cs.toEpochMilli()
        return (total / 60_000L).toInt()
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pendingPermission?.error("internal", "engine detached", null)
        pendingPermission = null
        scope.cancel()
    }

    companion object {
        const val CHANNEL = "illunis/health"
        const val REQUEST_CODE = 4103
        private const val DEFAULT_DAYS = 21
        private const val MAX_DAYS = 31
        private const val MAX_PAGES = 20

        val READ_SLEEP = HealthPermission.getReadPermission(SleepSessionRecord::class)
        val READ_STEPS = HealthPermission.getReadPermission(StepsRecord::class)
        val READ_HEART_RATE = HealthPermission.getReadPermission(HeartRateRecord::class)
        val PERMISSIONS = setOf(READ_SLEEP, READ_STEPS, READ_HEART_RATE)

        private val AWAKE_STAGES = setOf(
            SleepSessionRecord.STAGE_TYPE_AWAKE,
            SleepSessionRecord.STAGE_TYPE_OUT_OF_BED,
            SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED,
        )
    }
}
