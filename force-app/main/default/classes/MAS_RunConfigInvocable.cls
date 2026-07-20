/**
 * Invocable action so a Flow, Process, or other automation can trigger a Mass
 * Action Scheduler configuration on demand, by record Id or by Developer Name.
 */
public with sharing class MAS_RunConfigInvocable {
    public class Request {
        @InvocableVariable(label='Configuration Id' description='Id of the MAS_Configuration__c to run.')
        public Id configId;

        @InvocableVariable(label='Configuration Developer Name' description='Developer_Name__c of the configuration to run (used when Configuration Id is blank).')
        public String developerName;

        @InvocableVariable(label='Batch Size Override' description='Optional scope size; falls back to the configuration batch size.')
        public Integer batchSize;
    }

    public class Response {
        @InvocableVariable(label='Batch Job Id')
        public Id jobId;
    }

    @InvocableMethod(label='Run Mass Action Configuration' description='Launches a Mass Action Scheduler configuration batch by Id or Developer Name.')
    public static List<Response> run(List<Request> requests) {
        // Collect developer names so we can resolve Ids in a single query.
        Set<String> devNames = new Set<String>();
        for (Request req : requests) {
            if (req.configId == null && String.isNotBlank(req.developerName)) {
                devNames.add(req.developerName);
            }
        }
        Map<String, Id> idByDevName = new Map<String, Id>();
        if (!devNames.isEmpty()) {
            for (MAS_Configuration__c c : [
                SELECT Id, Developer_Name__c FROM MAS_Configuration__c WHERE Developer_Name__c IN :devNames
            ]) {
                idByDevName.put(c.Developer_Name__c, c.Id);
            }
        }

        // Preload batch sizes for configs that don't override it.
        Set<Id> configIds = new Set<Id>();
        for (Request req : requests) {
            Id cfgId = (req.configId != null) ? req.configId : idByDevName.get(req.developerName);
            if (cfgId != null) {
                configIds.add(cfgId);
            }
        }
        Map<Id, MAS_Configuration__c> configsById = new Map<Id, MAS_Configuration__c>([
            SELECT Id, Batch_Size__c FROM MAS_Configuration__c WHERE Id IN :configIds
        ]);

        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Id cfgId = (req.configId != null) ? req.configId : idByDevName.get(req.developerName);
            Response resp = new Response();
            if (cfgId != null && configsById.containsKey(cfgId)) {
                Integer scopeSize = (req.batchSize != null && req.batchSize > 0)
                    ? MAS_Utils.resolveBatchSize(req.batchSize)
                    : MAS_Utils.resolveBatchSize(configsById.get(cfgId).Batch_Size__c);
                resp.jobId = Database.executeBatch(new MAS_BatchRunner(cfgId), scopeSize);
            }
            responses.add(resp);
        }
        return responses;
    }
}
