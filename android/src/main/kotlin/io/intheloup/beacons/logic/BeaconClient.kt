//  Copyright (c) 2018 Loup Inc.
//  Licensed under Apache License v2.0

package io.intheloup.beacons.logic

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import io.intheloup.beacons.data.*
import kotlinx.coroutines.experimental.android.UI
import kotlinx.coroutines.experimental.launch
import org.altbeacon.beacon.*
import org.altbeacon.beacon.logging.LogManager
import org.altbeacon.beacon.logging.Loggers
import org.altbeacon.beacon.startup.BootstrapNotifier
import org.altbeacon.beacon.startup.RegionBootstrap
import java.util.*


class BeaconClient(private val permissionClient: PermissionClient) : BeaconConsumer, RangeNotifier, MonitorNotifier, BootstrapNotifier {

    private var activity: Activity? = null
    private var beaconManager: BeaconManager? = null
    private var isServiceConnected = false
    private var isPaused = false

    private var regionBootstrap: RegionBootstrap? = null
    private val requests: ArrayList<ActiveRequest> = ArrayList()

    fun bind(activity: Activity) {
        this.activity = activity
        beaconManager = BeaconManager.getInstanceForApplication(activity)

        // Add parsing support for iBeacon and Eddystone
        // https://beaconlayout.wordpress.com/
        beaconManager!!.beaconParsers.add(BeaconParser().setBeaconLayout("m:2-3=0215,i:4-19,i:20-21,i:22-23,p:24-24"))
        beaconManager!!.beaconParsers.add(BeaconParser().setBeaconLayout("x,s:0-1=feaa,m:2-2=20,d:3-3,d:4-5,d:6-7,d:8-11,d:12-15"))
        beaconManager!!.beaconParsers.add(BeaconParser().setBeaconLayout("s:0-1=feaa,m:2-2=00,p:3-3:-41,i:4-13,i:14-19"))
        beaconManager!!.beaconParsers.add(BeaconParser().setBeaconLayout("s:0-1=feaa,m:2-2=10,p:3-3:-41,i:4-20v"))

        beaconManager!!.bind(this)
    }

    fun unbind() {
        beaconManager!!.removeRangeNotifier(this)
        beaconManager!!.removeMonitorNotifier(this)
        beaconManager!!.unbind(this)
        activity = null
        isServiceConnected = false
    }


    // Beacons api

    fun configure(settings: Settings) {
        when (settings.logs) {
            Settings.Logs.Empty -> {
                LogManager.setVerboseLoggingEnabled(false)
                LogManager.setLogger(Loggers.empty())
            }
            Settings.Logs.Info -> {
                LogManager.setVerboseLoggingEnabled(false)
                LogManager.setLogger(Loggers.infoLogger())
            }
            Settings.Logs.Warning -> {
                LogManager.setVerboseLoggingEnabled(false)
                LogManager.setLogger(Loggers.warningLogger())
            }
            Settings.Logs.Verbose -> {
                LogManager.setVerboseLoggingEnabled(true)
                LogManager.setLogger(Loggers.verboseLogger())
            }
        }
    }

    fun addBackgroundMonitoringCallback(callback: (BackgroundMonitoringEvent) -> Unit) {
        if (BeaconClient.backgroundNotifier == null) return

        BeaconClient.backgroundNotifier!!.backgroundMonitoringCallbacks.add(callback)

    }

    fun addRequest(request: ActiveRequest, permission: Permission) {
        try {
            request.region.initFrameworkValue()
        } catch (e: Exception) {
            request.callback(Result.failure(Result.Error.Type.Runtime, request.region, e.message))
            return
        }

        if (request.inBackground && request.kind == ActiveRequest.Kind.Monitoring && BeaconClient.backgroundNotifier == null) {
            request.callback(Result.failure(Result.Error.Type.Runtime, request.region, "In order to use background monitoring on Android, you must subclass FlutterApplication and register it using BeaconsPlugin.registerApplication(app). See readme for details."))
            return
        }

        requests.add(request)

        launch(UI) {
            if (requests.count { request === it } == 0) {
                return@launch
            }

            val result = permissionClient.request(permission)
            if (result !== PermissionClient.PermissionResult.Granted) {
                request.callback(result.result)
                return@launch
            }

            startRequest(request)
        }
    }

    fun removeRequest(request: ActiveRequest) {
        val index = requests.indexOfFirst { request === it }
        if (index == -1) return

        stopRequest(request)
        requests.removeAt(index)
    }


    // Lifecycle api

    fun resume() {
        isPaused = false
        requests.filter { !it.isRunning }
                .forEach { startRequest(it) }
    }

    fun pause() {
        isPaused = true
        requests.filter { it.isRunning && !it.inBackground }
                .forEach { stopRequest(it) }
    }


    // Internals

    private fun startRequest(request: ActiveRequest) {
        if (!isServiceConnected) return

        if (requests.count { it.region.identifier == request.region.identifier && it.kind == request.kind && it.isRunning } == 0) {
            when (request.kind) {
                ActiveRequest.Kind.Ranging -> beaconManager!!.startRangingBeaconsInRegion(request.region.frameworkValue)
                ActiveRequest.Kind.Monitoring -> {
                    if (request.inBackground) {
                        if (regionBootstrap == null) {
                            regionBootstrap = RegionBootstrap(BeaconClient.backgroundNotifier, request.region.frameworkValue)
                        } else {
                            regionBootstrap!!.addRegion(request.region.frameworkValue)
                        }
                    } else {
                        beaconManager!!.startMonitoringBeaconsInRegion(request.region.frameworkValue)
                    }
                }
            }
        }

        request.isRunning = true
    }

    private fun stopRequest(request: ActiveRequest) {
        request.isRunning = false
        if (!isServiceConnected) return

        if (requests.count { it.region.identifier == request.region.identifier && it.kind == request.kind && it.isRunning } == 0) {
            when (request.kind) {
                ActiveRequest.Kind.Ranging -> beaconManager!!.stopRangingBeaconsInRegion(request.region.frameworkValue)
                ActiveRequest.Kind.Monitoring -> {
                    if (request.inBackground) {
                        regionBootstrap!!.removeRegion(request.region.frameworkValue)
                    } else {
                        beaconManager!!.stopMonitoringBeaconsInRegion(request.region.frameworkValue)
                    }
                }
            }
        }
    }

//    private fun isRunningInBackground(): Boolean {
//        val myProcess = RunningAppProcessInfo()
//        ActivityManager.getMyMemoryState(myProcess)
//        return myProcess.importance != RunningAppProcessInfo.IMPORTANCE_FOREGROUND
//    }


    // RangeNotifier

    override fun didRangeBeaconsInRegion(beacons: MutableCollection<Beacon>, region: Region) {
        requests.filter { it.kind == ActiveRequest.Kind.Ranging && it.region.identifier == region.uniqueId }
                .forEach { it.callback(Result.success(beacons.map { BeaconModel.parse(it) }, RegionModel.parse(region))) }
    }


    // MonitoringNotifier

    override fun didDetermineStateForRegion(state: Int, region: Region) {

    }

    override fun didEnterRegion(region: Region) {
        requests.filter { it.kind == ActiveRequest.Kind.Monitoring && it.region.identifier == region.uniqueId }
                .forEach { it.callback(Result.success(MonitoringState.EnterOrInside, RegionModel.parse(region))) }
    }

    override fun didExitRegion(region: Region) {
        requests.filter { it.kind == ActiveRequest.Kind.Monitoring && it.region.identifier == region.uniqueId }
                .forEach { it.callback(Result.success(MonitoringState.ExitOrOutside, RegionModel.parse(region))) }
    }


    // BeaconsConsumer

    override fun getApplicationContext(): Context {
        return activity!!.applicationContext
    }

    override fun unbindService(p0: ServiceConnection?) {
        return activity!!.unbindService(p0)
    }

    override fun bindService(p0: Intent?, p1: ServiceConnection?, p2: Int): Boolean {
        return activity!!.bindService(p0, p1, p2)
    }

    override fun onBeaconServiceConnect() {
        isServiceConnected = true
        beaconManager!!.addRangeNotifier(this)
        beaconManager!!.addMonitorNotifier(this)

        requests
                .filter { !it.isRunning && (!isPaused || it.inBackground) }
                .forEach { startRequest(it) }
    }

    class ActiveRequest(
            val kind: Kind,
            val region: RegionModel,
            val inBackground: Boolean,
            val callback: (Result) -> Unit
    ) {
        var isRunning: Boolean = false

        enum class Kind {
            Ranging, Monitoring
        }
    }

    companion object {
        var backgroundNotifier: BackgroundNotifier? = null
    }
}