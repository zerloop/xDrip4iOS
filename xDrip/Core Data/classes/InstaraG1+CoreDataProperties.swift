//
//  InstaraG1+CoreDataProperties.swift
//  xdrip
//

import Foundation
import CoreData

extension InstaraG1 {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<InstaraG1> {
        return NSFetchRequest<InstaraG1>(entityName: "InstaraG1")
    }

    /// blePeripheral is required to conform to protocol BluetoothPeripheral
    @NSManaged public var blePeripheral: BLEPeripheral

    /// hardware / software version from the handshake (0xF0), if received
    @NSManaged public var firmware: String?

}
