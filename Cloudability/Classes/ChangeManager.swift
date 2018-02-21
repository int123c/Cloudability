//
//  ChangeManager.swift
//  BestBefore
//
//  Created by Shangxin Guo on 30/10/2017.
//  Copyright © 2017 Inti Guo. All rights reserved.
//

import Foundation
import CloudKit
import PromiseKit
import RealmSwift

class ChangeManager {
    enum ChangeError: Error {
        case RecordDataNotComplete
    }
    
    private struct Deletion {
        let syncedEntity: SyncedEntity
    }
    
    private struct Modification {
        let syncedEntity: SyncedEntity?
        let record: CKRecord
    }
    
    weak var cloud: Cloud?
    
    var collectionObservations = [NotificationToken]()
    let zoneType: ZoneType
    var objectConverter: ObjectConverter {
        return .init(zoneType: zoneType)
    }
    
    init(zoneType: ZoneType = .individualForEachRecordType) {
        self.zoneType = zoneType
        validateCloudableObjects()
        setupLocalDatabaseObservations()
    }
    
    deinit {
        collectionObservations.forEach { $0.invalidate() }
    }
}

extension ChangeManager {
    
    /// Check if CloudableObjects conforms to requirements.
    func validateCloudableObjects() {
        let realm = try! Realm()
        for schema in realm.schema.objectSchema {
            let objClass = realmObjectType(forName: schema.className)!
            guard let _ = objClass as? CloudableObject.Type else { continue }
            assert(schema.primaryKeyProperty != nil, "\(schema.className) should provide a primary key.")
            assert(schema.primaryKeyProperty!.type == .string, "\(schema.className)'s primary key must be String.")
        }
    }
    
    func handleSyncronizationGet(modification: [CKRecord], deletion: [CKRecordID]) {
        let realm = Realm.cloudRealm
        let m: [Modification] = modification.map {
                return Modification(syncedEntity: realm.syncedEntity(withIdentifier: $0.recordID.recordName),
                                    record: $0)
            }
    
        let d: [Deletion] = deletion
            .flatMap { recordID in
                let identifier = recordID.recordName
                guard let se = realm.syncedEntity(withIdentifier: identifier) else { return nil }
                return Deletion(syncedEntity: SyncedEntity(value: se))
            }
        
        writeToDisk(modification: m, deletion: d)
    }
    
    func finishUploads(saved: [CKRecord]?, deleted: [CKRecordID]?) {
        let realm = Realm.cloudRealm
        let savedEntities: [SyncedEntity] = saved?
            .flatMap { record in
                let id = record.recordID.recordName
                return realm.syncedEntity(withIdentifier: id)
            } ?? []
        let deletedEntites: [SyncedEntity] = deleted?
            .flatMap { recordID in
                return realm.syncedEntity(withIdentifier: recordID.recordName)
            } ?? []
        
        try? realm.safeWrite {
            for entity in savedEntities {
                entity.changeState = .synced
                entity.modifiedTime = Date()
                realm.add(entity, update: true)
            }
            
            for entity in deletedEntites {
                entity.modifiedTime = Date()
                entity.isDeleted = true
                realm.add(entity, update: true)
            }
        }
    }
    
    func cleanUp() {
        let realm = Realm.cloudRealm
        try? realm.safeWrite {
            let deletedSyncedEntities = realm.objects(SyncedEntity.self).filter("isDeleted == true")
            let appliedPendingRelationships = realm.objects(PendingRelationship.self).filter("isApplied == true")
            realm.delete(deletedSyncedEntities)
            realm.delete(appliedPendingRelationships)
        }
    }
}

extension ChangeManager {
    func setupSyncedEntitiesIfNeeded() {
        let cRealm = Realm.cloudRealm
        let oRealm = try! Realm()
        guard cRealm.objects(SyncedEntity.self).count <= 0 else {
            log("ChangeManager >> Synced entities already setup.")
            return
        }
        
        log("ChangeManager >> Setting up synced entities.")
        
        try? cRealm.safeWrite() {
            for schema in cRealm.schema.objectSchema {
                let objectClass = realmObjectType(forName: schema.className)!
                guard objectClass is CloudableObject.Type else { continue }
                let primaryKey = objectClass.primaryKey()!
                let results = oRealm.objects(objectClass)
                
                let syncedEntities = results.map {
                    SyncedEntity(type: schema.className, identifier: $0[primaryKey] as! String, state: 0)
                }
                
                cRealm.add(syncedEntities)
            }
        }
        
        log("ChangeManager >> All synced entities setup.")
    }
    
    func detachSyncedEntities() {
        let realm = Realm.cloudRealm
        try? realm.safeWrite() {
            _ = realm.syncedEntities.map(realm.delete)
        }
    }
    
    /// Observe all Cloudable object lists, for insertions and modifications.
    private func setupLocalDatabaseObservations() {
        let realm = try! Realm()
        for schema in realm.schema.objectSchema {
            let objClass = realmObjectType(forName: schema.className)!
            guard let objectClass = objClass as? CloudableObject.Type else { continue }
            let results = realm.objects(objectClass)
            
            let token = results.observe { [weak self] change in
                switch change {
                case .initial: break
                case .error(let e): log(e.localizedDescription)
                    
                // We should not see any true deletion, soft deletion should be used in Cloudable objects.
                case let .update(result, _, insertion, modification):
                    log("ChangeManager >> Change detected.")
                    guard let ego = self else { return }
                    
                    /// All insertions and modifications, not marked as soft deleted
                    let m: [CloudableObject] = (insertion + modification)
                        .filter { $0 < result.count }
                        .map { result[$0] as! CloudableObject }
                    
                    ego.handleLocalModification(modification: m)
                    let uploads = ego.generateUploads(forSpecificType: objectClass)
                    ego.cloud?.push(modification: uploads.modification, deletion: uploads.deletion)
                }
            }
            collectionObservations.append(token)
        }
    }
    
    func generateAllUploads() -> (modification: [CKRecord], deletion: [CKRecordID]) {
        let realm = try! Realm()
        var modification = [CKRecord]()
        var deletion = [CKRecordID]()
        realm.enumerateCloudableTypes { type in
            let upload = generateUploads(forSpecificType: type)
            modification.append(contentsOf: upload.modification)
            deletion.append(contentsOf: upload.deletion)
        }
        
        return (modification, deletion)
    }
    
    func generateUploads(forSpecificType type: CloudableObject.Type? = nil) -> (modification: [CKRecord], deletion: [CKRecordID]) {
        let oRealm = try! Realm()
        let cRealm = Realm.cloudRealm
        
        func syncedEntity(of changeState: [SyncedEntity.ChangeState]) -> [SyncedEntity] {
            if let type = type {
                return Array(cRealm.syncedEntities(of: changeState).filter("type == \"\(type.className())\""))
            }
            return Array(cRealm.syncedEntities(of: changeState))
        }
        
        let uploadingModificationSyncedEntities = syncedEntity(of: [.new, .changed])
        let uploadingDeletionSyncedEntities = syncedEntity(of: [.deleted])
        
        let converter = objectConverter
        
        let modification: [CKRecord] = uploadingModificationSyncedEntities.flatMap {
            let object = oRealm.object(ofType: $0.objectType, forPrimaryKey: $0.identifier)
            return (object as? CloudableObject).map(converter.convert)
        }
        
        let deletion: [CKRecordID] = uploadingDeletionSyncedEntities.map {
            return CKRecordID(recordName: $0.identifier, zoneID: converter.zoneID(for: $0.objectType))
        }
        
        return (modification, deletion)
    }
    
    /// Write modifications and deletions to disk.
    private func writeToDisk(modification: [Modification], deletion: [Deletion]) {
        log("ChangeManager >> Writing deletions.")
        writeToDisk(deletion: deletion)
        
        log("ChangeManager >> Writing modifications.")
        writeToDisk(modification: modification)
        
        log("ChangeManager >> Writing relationships.")
        applyPendingRelationships()
    }
    
    private func applyPendingRelationships() {
        let cRealm = Realm.cloudRealm
        let oRealm = try! Realm()
        let toBeDeleted = List<PendingRelationship>()
        for relationship in cRealm.pendingRelationships {
            do {
                try oRealm.safeWrite(withoutNotifying: collectionObservations) {
                    try oRealm.apply(relationship)
                }
                try cRealm.safeWrite {
                    relationship.isApplied = true
                }
                toBeDeleted.append(relationship)
            } catch PendingRelationshipError.partiallyConnected {
                log("Can not fullfill PendingRelationship \(relationship.fromType).\(relationship.propertyName)")
            } catch PendingRelationshipError.dataCorrupted {
                log("Data corrupted for PendingRelationship \(relationship.fromType).\(relationship.propertyName)")
                toBeDeleted.append(relationship)
            } catch {
                logError(error.localizedDescription)
            }
        }
        
        
        try? cRealm.safeWrite {
            cRealm.delete(toBeDeleted)
        }
        
    }
    
    /// Update `SyncedEntities`.
    private func handleLocalModification(modification: [CloudableObject]) {
        let realm = Realm.cloudRealm
        let mSyncedEntities = modification.map {
            realm.syncedEntity(withIdentifier: $0.pkProperty) ?? SyncedEntity(type: $0.recordType, identifier: $0.pkProperty, state: SyncedEntity.ChangeState.new.rawValue)
        }
        
        try? realm.safeWrite() {
            for m in mSyncedEntities {
                m.changeState = .changed
                realm.add(m, update: true)
            }
        }
    }
    
    var allZoneIDs: [CKRecordZoneID] {
        let realm = try! Realm()
        switch zoneType {
        case .individualForEachRecordType:
            var result = [CKRecordZoneID]()
            realm.enumerateCloudableTypes { type in
                result.append(objectConverter.zoneID(for: type))
            }
            return result
        case .customRule(let rule):
            var result = [CKRecordZoneID]()
            realm.enumerateCloudableTypes { type in
                result.append(rule(type))
            }
            return result
        case .defaultZone:
            return [CKRecordZone.default().zoneID]
        case .sameZone(let name):
            return [CKRecordZoneID(zoneName: name, ownerName: CKCurrentUserDefaultName)]
        }
    }
 }

extension ChangeManager {
    private func writeToDisk(deletion: [Deletion]) {
        let oRealm = try! Realm()
        let cRealm = Realm.cloudRealm
        try? oRealm.safeWrite(withoutNotifying: collectionObservations) {
            for d in deletion {
                let syncedEntity = d.syncedEntity
                let identifier = syncedEntity.identifier
                let type = realmObjectType(forName: syncedEntity.type)!
                let object = oRealm.object(ofType: type, forPrimaryKey: identifier)
                oRealm.add(syncedEntity, update: true)
                if let object = object as? CloudableObject {
                    oRealm.delete(object)
                }
            }
        }
        
        try? cRealm.safeWrite() {
            for d in deletion {
                let syncedEntity = d.syncedEntity
                syncedEntity.isDeleted = true
                syncedEntity.changeState = .synced
                cRealm.add(syncedEntity, update: true)
            }
        }
    }
    
    private func writeToDisk(modification: [Modification]) {
        let oRealm = try! Realm()
        let cRealm = Realm.cloudRealm
        let pendingRelationshipsToBeAdded = List<PendingRelationship>()
        let syncedEntitiesToBeUpdated = List<SyncedEntity>()
        try? oRealm.safeWrite(withoutNotifying: collectionObservations) {
            for m in modification {
                let ckRecord = m.record
                let (object, pendingRelationships) = objectConverter.convert(ckRecord)
                let syncedEntity = m.syncedEntity
                                ?? SyncedEntity(type: ckRecord.recordType, identifier: ckRecord.recordID.recordName, state: 0)
                oRealm.add(object, update: true)
                pendingRelationshipsToBeAdded.append(objectsIn: pendingRelationships)
                syncedEntitiesToBeUpdated.append(syncedEntity)
            }
        }
        
        try? cRealm.safeWrite() {
            cRealm.add(pendingRelationshipsToBeAdded, update: true)
            syncedEntitiesToBeUpdated.forEach { $0.changeState = .synced }
            cRealm.add(syncedEntitiesToBeUpdated, update: true)
        }
    }
}

