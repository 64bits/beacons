//
//  Copyright (c) 2018 Loup Inc.
//  Licensed under Apache License v2.0
//

import Foundation
import CoreLocation
import streams_channel

class Channel {
  
  private let locationClient: LocationClient
  
  init(locationClient: LocationClient) {
    self.locationClient = locationClient
  }
  
  func register(on plugin: SwiftBeaconsPlugin) {
    let methodChannel = FlutterMethodChannel(name: "beacons", binaryMessenger: plugin.registrar.messenger())
    methodChannel.setMethodCallHandler(handleMethodCall(_:result:))
    
    let rangingChannel = FlutterStreamsChannel(name: "beacons/ranging", binaryMessenger: plugin.registrar.messenger())
    rangingChannel.setStreamHandlerFactory { _ in Handler(locationClient: self.locationClient, kind: .ranging) }
    
    let monitoringChannel = FlutterStreamsChannel(name: "beacons/monitoring", binaryMessenger: plugin.registrar.messenger())
    monitoringChannel.setStreamHandlerFactory { _ in Handler(locationClient: self.locationClient, kind: .monitoring) }
  }
  
  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkStatus":
      checkStatus(for: Codec.decodeStatusRequest(from: call.arguments), on: result)
    case "requestPermission":
      request(permission: Codec.decodePermission(from: call.arguments), on: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
  
  private func checkStatus(for request: StatusRequest, on flutterResult: @escaping FlutterResult) {
    flutterResult(Codec.encode(result: locationClient.checkStatus(for: request)))
  }
  
  private func request(permission: Permission, on flutterResult: @escaping FlutterResult) {
    locationClient.request(permission: permission) { result in
      flutterResult(Codec.encode(result: result))
    }
  }
  
  class Handler: NSObject, FlutterStreamHandler {
    private let locationClient: LocationClient
    private let kind: LocationClient.ActiveRequest.Kind
    private var request: LocationClient.ActiveRequest?
    
    init(locationClient: LocationClient, kind: LocationClient.ActiveRequest.Kind) {
      self.kind = kind
      self.locationClient = locationClient
    }
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
      let dataRequest = Codec.decodeDataRequest(from: arguments)
      
      request = LocationClient.ActiveRequest(kind: kind, region: dataRequest.region, inBackground: dataRequest.inBackground) { result in
        events(Codec.encode(result: result))
      }
      locationClient.add(request: request!, with: dataRequest.permission)
      
      return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
      locationClient.remove(request: request!)
      request = nil
      
      return nil
    }
  }
}
