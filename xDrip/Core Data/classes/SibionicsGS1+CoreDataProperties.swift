//
//  SibionicsGS1+CoreDataProperties.swift
//  xdrip
//

import Foundation
import CoreData

extension SibionicsGS1 {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<SibionicsGS1> {
        return NSFetchRequest<SibionicsGS1>(entityName: "SibionicsGS1")
    }

    /// blePeripheral is required to conform to protocol BluetoothPeripheral
    @NSManaged public var blePeripheral: BLEPeripheral

    /// firmware version, if discovered
    @NSManaged public var firmware: String?

}
