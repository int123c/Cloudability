//
//  ObjectConverter.swift
//  BestBefore
//
//  Created by Shangxin Guo on 12/11/2017.
//  Copyright © 2017 Inti Guo. All rights reserved.
//

import RealmSwift
import Realm
import CloudKit

func realmObjectType(forName name: String) -> Object.Type? {
    return RLMSchema.class(for: name) as? Object.Type // let Realm do the job
}

class ObjectConverter {
    let zoneType: ZoneType
    
    init(zoneType: ZoneType) {
        self.zoneType = zoneType
    }
    
    func zoneID(for objectType: CloudableObject.Type) -> CKRecordZoneID {
        switch zoneType {
        case .individualForEachRecordType:
            return CKRecordZoneID(zoneName: objectType.recordType, ownerName: CKCurrentUserDefaultName)
        case .customRule(let rule):
            return rule(objectType)
        case .defaultZone:
            return CKRecordZone.default().zoneID
        case .sameZone(let name):
            return CKRecordZoneID(zoneName: name, ownerName: CKCurrentUserDefaultName)
        }
    }
    
    func recordID(for object: CloudableObject) -> CKRecordID {
        let className = object.className
        let objClass = realmObjectType(forName: className)!
        let objectClass = objClass as! CloudableObject.Type
        return CKRecordID(recordName: object.pkProperty, zoneID: zoneID(for: objectClass))
    }
    
    func convert(_ object: CloudableObject) -> CKRecord {
        let propertyList = object.objectSchema.properties
        let recordID = self.recordID(for: object)
        let record = CKRecord(recordType: object.recordType, recordID: recordID)
        let nonSyncedProperties = object.nonSyncedProperties
        
        for property in propertyList where !nonSyncedProperties.contains(property.name) {
            record[property.name] = convert(property, of: object)
        }
        let realm = try! Realm()
        record["schemaVersion"] = NSNumber(value: realm.configuration.schemaVersion)
        
        return record
    }
    
    func convert(_ record: CKRecord) -> (CloudableObject, [PendingRelationship]) {
        let (recordType, id) = (record.recordType, record.recordID.recordName)
        let type = realmObjectType(forName: recordType) as! CloudableObject.Type
        let object = type.init()
        
        var pendingRelationships = [PendingRelationship]()
        object.pkProperty = id
        let nonSyncedProperties = object.nonSyncedProperties
        
        let propertyList = object.objectSchema.properties
        for property in propertyList where property.name != type.primaryKey() && !nonSyncedProperties.contains(property.name) {
            let recordValue = record[property.name]
            
            let isOptional = property.isOptional
            let isArray = property.isArray
            switch property.type {
            case .int:
                object[property.name] =
                    isArray
                    ? (recordValue as? Array<NSNumber>)?.map({ $0.intValue }) ?? [Int]()
                    : isOptional
                        ? recordValue?.int
                        : recordValue?.int ?? 0
            case .bool:
                object[property.name] =
                    isArray
                    ? (recordValue as? Array<NSNumber>)?.map({ $0.boolValue }) ?? [Bool]()
                    : isOptional
                        ? recordValue?.bool
                        : recordValue?.bool ?? false
            case .float:
                object[property.name] =
                    isArray
                    ? (recordValue as? Array<NSNumber>)?.map({ $0.floatValue }) ?? [Float]()
                    : isOptional
                        ? recordValue?.float
                        : recordValue?.float ?? 0
            case .double:
                object[property.name] =
                    isArray
                    ? (recordValue as? Array<NSNumber>)?.map({ $0.doubleValue }) ?? [Double]()
                    : isOptional
                        ? recordValue?.double
                        : recordValue?.double ?? 0
            case .string:
                object[property.name] =
                    isArray
                    ? (recordValue as? Array<String>) ?? [String]()
                    : isOptional
                    ? recordValue?.string
                    : recordValue?.string ?? ""
            case .data:
                object[property.name] =
                    isArray
                    ? (recordValue as? Array<Data>) ?? [Data]()
                    : isOptional
                        ? recordValue?.data
                        : recordValue?.data ?? Data()
            case .any:
                object[property.name] = recordValue
            case .date:
                object[property.name] =
                    isArray
                    ? (recordValue as? Array<Data>) ?? [Date]()
                    : isOptional
                        ? recordValue?.date
                        : recordValue?.date ?? Date()
                
            // when things a relationship
            case .object:
                if isArray {
                    guard let recordValue = recordValue else { break }
                    let ids = recordValue.list as! [String]
                    let relationship: PendingRelationship = {
                        let p = PendingRelationship()
                        p.fromType = recordType
                        p.fromIdentifier = id
                        p.toType = property.objectClassName!
                        p.propertyName = property.name
                        p.targetIdentifiers.append(objectsIn: ids)
                        return p
                    }()
                    pendingRelationships.append(relationship)
                } else {
                    let relationship: PendingRelationship = {
                        let p = PendingRelationship()
                        p.fromType = recordType
                        p.fromIdentifier = id
                        p.toType = property.objectClassName!
                        p.propertyName = property.name
                        if let id = recordValue?.string {
                            p.targetIdentifiers.append(id)
                        }
                        return p
                    }()
                    pendingRelationships.append(relationship)
                }
                
            case .linkingObjects: break // ignored
            }
        }
        
        return (object, pendingRelationships)
    }
    
    private func convert(_ property: Property, of object: Object) -> CKRecordValue? {
        guard let value = object.value(forKey: property.name) else { return nil }
        let isArray = property.isArray

        switch property.type {
        case .int:
            if isArray {
                return (value as? [Int])?.map(NSNumber.init(value:)) as NSArray?
            }
            return (value as? Int).map(NSNumber.init(value:))
        case .bool:
            if isArray {
                return (value as? [Bool])?.map(NSNumber.init(value:)) as NSArray?
            }
            return (value as? Bool).map(NSNumber.init(value:))
        case .float:
            if isArray {
                return (value as? [Float])?.map(NSNumber.init(value:)) as NSArray?
            }
            return (value as? Float).map(NSNumber.init(value:))
        case .double:
            if isArray {
                return (value as? [Double])?.map(NSNumber.init(value:)) as NSArray?
            }
            return (value as? Double).map(NSNumber.init(value:))
        case .string:
            if isArray {
                return (value as? [String]) as NSArray?
            }
            return value as? String as CKRecordValue?
        case .data:
            if isArray {
                return (value as? [Data]) as NSArray?
            }
            return (value as? Data).map(NSData.init(data:))
        case .any:
            return value as? CKRecordValue
        case .date:
            if isArray {
                return (value as? [Date]) as NSArray?
            }
            return value as? Date as CKRecordValue?
            
        case .object:
            if !isArray {
                guard let object = value as? CloudableObject
                    else { return nil }
                return object.pkProperty as CKRecordValue
            } else {
                let className = property.objectClassName!
                let targetType = realmObjectType(forName: className)!
                let list = object.dynamicList(property.name)
                guard let targetPrimaryKey = targetType.primaryKey() else { return nil }
                let ids = list.flatMap { $0.value(forKey: targetPrimaryKey) as? String }
                if ids.isEmpty { return nil }
                return ids as NSArray
            }
        case .linkingObjects: return nil
        }
    }
}

extension CKRecordValue {
    var date: Date? {
        return self as? NSDate as Date?
    }
    
    var bool: Bool? {
        return (self as? NSNumber)?.boolValue
    }
    
    var int: Int? {
        return (self as? NSNumber)?.intValue
    }
    
    var double: Double? {
        return (self as? NSNumber)?.doubleValue
    }
    
    var float: Float? {
        return (self as? NSNumber)?.floatValue
    }
    
    var string: String? {
        return self as? String
    }
    
    var data: Data? {
        return (self as? NSData).map(Data.init(referencing:))
    }
    
    var asset: CKAsset? {
        return self as? CKAsset
    }
    
    var location: CLLocation? {
        return self as? CLLocation
    }
    
    var list: Array<Any>? {
        guard let array = self as? NSArray else { return nil }
        return Array(array)
    }
}

