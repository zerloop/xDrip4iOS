//
//  SibionicsGS1+CoreDataClass.swift
//  xdrip
//

import Foundation
import CoreData

/// Sibionics GS1 passive co-listener peripheral. Session state (last received index, sensor start)
/// lives in UserDefaults like Medtrum; this entity only carries firmware.
public class SibionicsGS1: NSManagedObject {

    init(address: String, name: String, alias: String?, nsManagedObjectContext: NSManagedObjectContext) {

        let entity = NSEntityDescription.entity(forEntityName: "SibionicsGS1", in: nsManagedObjectContext)!

        super.init(entity: entity, insertInto: nsManagedObjectContext)

        blePeripheral = BLEPeripheral(address: address, name: name, alias: alias, bluetoothPeripheralType: .SibionicsGS1Type, nsManagedObjectContext: nsManagedObjectContext)

    }

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?) {
        super.init(entity: entity, insertInto: context)
    }

}
