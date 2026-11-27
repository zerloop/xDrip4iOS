//
//  InstaraG1+CoreDataClass.swift
//  xdrip
//

import Foundation
import CoreData

/// Instara G1 passive co-listener peripheral. Session state (last sequence number, sensor start)
/// lives in UserDefaults under the "instaraG1." prefix like Sibionics; this entity only carries firmware.
public class InstaraG1: NSManagedObject {

    init(address: String, name: String, alias: String?, nsManagedObjectContext: NSManagedObjectContext) {

        let entity = NSEntityDescription.entity(forEntityName: "InstaraG1", in: nsManagedObjectContext)!

        super.init(entity: entity, insertInto: nsManagedObjectContext)

        blePeripheral = BLEPeripheral(address: address, name: name, alias: alias, bluetoothPeripheralType: .InstaraG1Type, nsManagedObjectContext: nsManagedObjectContext)

    }

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?) {
        super.init(entity: entity, insertInto: context)
    }

}
