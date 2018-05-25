//
//  Copyright (c) 2018 Loup Inc.
//  Licensed under Apache License v2.0
//

import Foundation
import CoreLocation

class LocationClient : NSObject, CLLocationManagerDelegate {
  
  private let locationManager = CLLocationManager()
  private var permissionCallbacks: Array<Callback<Void, Void>> = []
  
  private var rangingRequests: Array<ActiveRequest<RangingCallback>> = [];
  private var monitoringRequests: Array<ActiveRequest<MonitoringCallback>> = [];
  
  override init() {
    super.init()
    locationManager.delegate = self
  }
  
  
  // Status
  
  func checkStatus(for request: StatusRequest) -> Result<Bool> {
    let status: ServiceStatus<Bool> = getStatus(for: request, region: nil)
    return status.isReady ? Result<Bool>.success(with: true) : status.failure!
  }
  
  func request(permission: Permission, _ callback: @escaping (Result<Bool>) -> Void) {
    runWithValidStatus(for: StatusRequest(ranging: false, monitoring: false, permission: permission), region: nil, success: {
      callback(Result<Bool>.success(with: true))
    }, failure: { result in
      callback(result)
    })
  }
  
  
  // Ranging
  
  func startRanging(for request: DataRequest, _ callback: @escaping RangingCallback) -> ActiveRequest<RangingCallback> {
    let activeRequest = ActiveRequest<RangingCallback>(region: request.region, callback: callback)
    rangingRequests.append(activeRequest)
    
    runWithValidStatus(for: StatusRequest(ranging: true, monitoring: false, permission: request.permission), region: request.region, success: {
      guard self.rangingRequests.contains(where: { $0 === activeRequest }) else {
        return
      }
      
      if !self.rangingRequests.contains(where: { $0.region.identifier == activeRequest.region.identifier && $0.isRunning }) {
        self.start(request: activeRequest, forRanging: true)
      }
      activeRequest.isRunning = true
      
    }, failure: { result in
      callback(result)
    })
    
    return activeRequest
  }
  
  func stopRanging(for request: ActiveRequest<RangingCallback>) {
    guard let index = rangingRequests.index(where:  { $0 === request }) else {
      return
    }
    
    if !rangingRequests.contains(where: { $0.region.identifier == request.region.identifier}) {
      stop(request: rangingRequests[index], forRanging: true)
    }
    
    rangingRequests.remove(at: index)
  }
  
  
  // Monitoring
  
//  func startMonitoring(for request: DataRequest) {
//    runWithValidStatus(for: StatusRequest(ranging: false, monitoring: true, permission: request.permission), region: request.region, success: {
//      let activeRequest = ActiveRequest(request: request, kind: .monitoring)
//      self.requests.append(activeRequest)
//      self.start(request: activeRequest)
//    }, failure: { result in
//      self.monitoringCallback?(result)
//    })
//  }
//
//  func stopMonitoring(for identifier: String) {
//    guard let index = requests.index(where: { $0.kind == .monitoring && $0.request.region.identifier == identifier }) else {
//      return
//    }
//
//    stop(request: requests[index])
//    requests.remove(at: index)
//  }
//
//  func registerMonitoringCallback(_ callback: @escaping MonitoringCallback) {
//    precondition(monitoringCallback == nil, "trying to register a 2nd monitoring callback")
//    monitoringCallback = callback
//  }
//
//  func deregisterMonitoringCallback() {
//    precondition(monitoringCallback != nil, "trying to deregister a non-existent monitoring callback")
//    monitoringCallback = nil
//  }
  
  
  // Lifecycle API
  
  func resume() {
//    requests
//      .filter { !$0.isRunning }
//      .forEach { start(request: $0) }
  }
  
  func pause() {
//    requests
//      .filter { $0.isRunning && !$0.request.inBackground }
//      .forEach { stop(request: $0) }
  }
  
  
  // Request
  
  private func start<T>(request: ActiveRequest<T>, forRanging isRanging: Bool) {
    request.isRunning = true
    if isRanging {
      locationManager.startRangingBeacons(in: request.region.clValue)
    } else {
      locationManager.startMonitoring(for: request.region.clValue)
    }
  }
  
  private func stop<T>(request: ActiveRequest<T>, forRanging isRanging: Bool) {
    request.isRunning = false
    if isRanging {
      locationManager.stopRangingBeacons(in: request.region.clValue)
    } else {
      locationManager.stopMonitoring(for: request.region.clValue)
    }
  }
  
  
  // Status
  
  private func runWithValidStatus<T>(for request: StatusRequest, region: BeaconRegion?, success: @escaping () -> Void, failure: @escaping (Result<T>) -> Void) {
    let status: ServiceStatus<T> = getStatus(for: request, region: region)
    
    if status.isReady {
      success()
    } else {
      if let permission = status.needsAuthorization {
        let callback = Callback<Void, Void>(
          success: { _ in success() },
          failure: { _ in failure(Result<T>.failure(of: .permissionDenied, for: region)) }
        )
        permissionCallbacks.append(callback)
        locationManager.requestAuthorization(for: permission)
      } else {
        failure(status.failure!)
      }
    }
  }
  
  private func getStatus<T>(for request: StatusRequest, region: BeaconRegion?) -> ServiceStatus<T> {
    if request.ranging || request.monitoring {
      guard CLLocationManager.locationServicesEnabled() else {
        return ServiceStatus<T>(isReady: false, needsAuthorization: nil, failure: Result<T>.failure(of: .serviceDisabled, for: region))
      }
      
      if request.ranging && !CLLocationManager.isRangingAvailable() {
        return ServiceStatus<T>(isReady: false, needsAuthorization: nil, failure: Result<T>.failure(of: .rangingUnavailable, for: region))
      }
      
      if request.monitoring && !CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) {
        return ServiceStatus<T>(isReady: false, needsAuthorization: nil, failure: Result<T>.failure(of: .monitoringUnavailable, for: region))
      }
    }
    
    if let permission = request.permission {
      switch CLLocationManager.authorizationStatus() {
      case .notDetermined:
        guard locationManager.isPermissionDeclared(for: permission) else {
          return ServiceStatus<T>(isReady: false, needsAuthorization: nil, failure: Result<T>.failure(of: .runtime, message: "Missing location usage description values in Info.plist. See readme for details.", fatal: true, for: region))
        }
        
        return ServiceStatus<T>(isReady: false, needsAuthorization: permission, failure: Result<T>.failure(of: .permissionDenied, for: region))
      case .denied:
        return ServiceStatus<T>(isReady: false, needsAuthorization: nil, failure: Result<T>.failure(of: .permissionDenied, for: region))
      case .restricted:
        return ServiceStatus<T>(isReady: false, needsAuthorization: nil, failure: Result<T>.failure(of: .serviceDisabled, for: region))
      case .authorizedWhenInUse, .authorizedAlways:
        if CLLocationManager.authorizationStatus() == .authorizedWhenInUse && permission == .always {
          return ServiceStatus<T>(isReady: false, needsAuthorization: permission, failure: nil)
        } else {
          return ServiceStatus<T>(isReady: true, needsAuthorization: nil, failure: nil)
        }
      }
    }
    
    return ServiceStatus<T>(isReady: true, needsAuthorization: nil, failure: nil)
  }
  
  
  // CLLocationManagerDelegate
  
  public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    permissionCallbacks.forEach { action in
      if status == .authorizedAlways || status == .authorizedWhenInUse {
        action.success(())
      } else {
        action.failure(())
      }
    }
    permissionCallbacks.removeAll()
  }
  
  func locationManager(_ manager: CLLocationManager, didRangeBeacons beacons: [CLBeacon], in region: CLBeaconRegion) {
    rangingRequests
      .filter { $0.region.identifier == region.identifier }
      .forEach {
        $0.callback(Result<[Beacon]>.success(with: beacons.map { Beacon(from: $0) }, for: BeaconRegion(from: region)))
      }
  }
  
  func locationManager(_ manager: CLLocationManager, rangingBeaconsDidFailFor region: CLBeaconRegion, withError error: Error) {
    rangingRequests
      .filter { $0.region.identifier == region.identifier }
      .forEach {
        $0.callback(Result<[Beacon]>.failure(of: .runtime, message: error.localizedDescription, for: BeaconRegion(from: region)))
      }
  }
  
  func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    guard region is CLBeaconRegion else { return }
//    monitoringCallback?(Result<MonitoringEvent>.success(with: .enter, for: BeaconRegion(from: region as! CLBeaconRegion)))
  }
  
  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard region is CLBeaconRegion else { return }
//    monitoringCallback?(Result<MonitoringEvent>.success(with: .exit, for: BeaconRegion(from: region as! CLBeaconRegion)))
  }
  
  func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
    guard region is CLBeaconRegion else { return }
//    monitoringCallback?(Result<[Beacon]>.failure(of: .runtime, message: error.localizedDescription, for: BeaconRegion(from: region as! CLBeaconRegion)))
  }
  
  func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
    let label: String
    switch state {
    case .inside:
      label = "inside"
    case .outside:
      label = "outside"
    case .unknown:
      label = "unknown"
    }
    
    print("new state [\(label)] for region: \(region.identifier)")
  }
  
  func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
    print("start monitoring for region: \(region.identifier)")
  }
  
  struct Callback<T, E> {
    let success: (T) -> Void
    let failure: (E) -> Void
  }
  
  typealias RangingCallback = (Result<[Beacon]>) -> Void
  
  typealias MonitoringCallback = (Result<MonitoringEvent>) -> Void
  
  struct ServiceStatus<T: Codable> {
    let isReady: Bool
    let needsAuthorization: Permission?
    let failure: Result<T>?
  }
  
  class ActiveRequest<T> {
    let region: BeaconRegion
    var callback: T;
    var isRunning: Bool = false
    
    init(region: BeaconRegion, callback: T) {
      self.region = region
      self.callback = callback
    }
  }
}
