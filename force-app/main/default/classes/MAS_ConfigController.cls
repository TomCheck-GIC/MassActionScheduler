/**
 * Apex surface for the Mass Action Scheduler LWC config wizard.
 *
 * Everything here is callout-free:
 *  - Flow list via FlowDefinitionView (SOQL)
 *  - Target input parameters via Invocable.Action.getDescribe().getInputs()
 *  - Source preview via Database.query
 *  - Run on demand via Database.executeBatch
 *  - Scheduling via System.schedule / System.abortJob
 */
public with sharing class MAS_ConfigController {
    // ---------------------------------------------------------------------
    // DTOs
    // ---------------------------------------------------------------------
    public class FlowOption {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
    }

    public class InputParam {
        @AuraEnabled public String name;
        @AuraEnabled public String label;
        @AuraEnabled public String dataType;
        @AuraEnabled public Boolean required;
        @AuraEnabled public String sObjectType;
    }

    public class PreviewResult {
        @AuraEnabled public List<String> columns = new List<String>();
        @AuraEnabled public List<Map<String, String>> rows = new List<Map<String, String>>();
        @AuraEnabled public Integer totalPreviewed = 0;
    }

    // ---------------------------------------------------------------------
    // Discovery
    // ---------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static List<FlowOption> getActiveFlows() {
        try {
            List<FlowOption> options = new List<FlowOption>();
            for (FlowDefinitionView f : [
                SELECT ApiName, Label
                FROM FlowDefinitionView
                WHERE ProcessType = 'AutoLaunchedFlow' AND IsActive = true
                ORDER BY Label
            ]) {
                FlowOption o = new FlowOption();
                o.apiName = f.ApiName;
                o.label = String.isBlank(f.Label) ? f.ApiName : f.Label;
                options.add(o);
            }
            return options;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load flows: ' + e.getMessage());
        }
    }

    /**
     * Returns the input parameters of a target Flow or Apex action, discovered
     * natively (no callout) via the Invocable.Action describe metadata.
     */
    @AuraEnabled
    public static List<InputParam> getActionInputs(String targetType, String actionName) {
        try {
            List<InputParam> params = new List<InputParam>();
            if (String.isBlank(actionName)) {
                return params;
            }
            String actionType = (targetType == 'Apex') ? 'apex' : 'flow';
            Invocable.Action action = Invocable.Action.createCustomAction(actionType, actionName);
            List<Invocable.Action.DescribeResult> describes = action.getDescribe();
            if (describes != null && !describes.isEmpty()) {
                for (Invocable.Action.InputParameter ip : describes[0].getInputs()) {
                    InputParam p = new InputParam();
                    p.name = ip.getName();
                    p.label = ip.getLabel();
                    p.dataType = ip.getType();
                    p.required = ip.getRequired();
                    p.sObjectType = ip.getSObjectType();
                    params.add(p);
                }
            }
            return params;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to describe target inputs: ' + e.getMessage());
        }
    }

    /**
     * Runs the configuration's SOQL (with an enforced small LIMIT) and returns
     * the selected columns plus a few sample rows for the mapping UI.
     */
    @AuraEnabled
    public static PreviewResult previewSource(String soql) {
        try {
            PreviewResult result = new PreviewResult();
            if (String.isBlank(soql)) {
                return result;
            }
            String query = soql.trim();
            if (!query.toLowerCase().contains(' limit ')) {
                query += ' LIMIT 5';
            }
            List<SObject> records = Database.query(query);
            result.totalPreviewed = records.size();
            result.columns = parseSelectColumns(soql);
            for (SObject record : records) {
                Map<String, String> row = new Map<String, String>();
                for (String col : result.columns) {
                    Object val = getFieldValue(record, col);
                    row.put(col, val == null ? '' : String.valueOf(val));
                }
                result.rows.add(row);
            }
            return result;
        } catch (Exception e) {
            throw new AuraHandledException('SOQL preview failed: ' + e.getMessage());
        }
    }

    // ---------------------------------------------------------------------
    // Run + schedule
    // ---------------------------------------------------------------------
    @AuraEnabled
    public static Id runNow(Id configId) {
        try {
            MAS_Configuration__c c = [SELECT Batch_Size__c FROM MAS_Configuration__c WHERE Id = :configId LIMIT 1];
            return Database.executeBatch(new MAS_BatchRunner(configId), MAS_Utils.resolveBatchSize(c.Batch_Size__c));
        } catch (Exception e) {
            throw new AuraHandledException('Unable to start run: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static String saveSchedule(Id configId, String cronExpression) {
        try {
            unschedule(configId);
            String jobName = 'MAS_' + configId;
            Id jobId = System.schedule(jobName, cronExpression, new MAS_Scheduler(configId));
            update new MAS_Configuration__c(
                Id = configId,
                Scheduled_Job_Id__c = jobId,
                Schedule_Type__c = 'Scheduled',
                Schedule_Cron__c = cronExpression
            );
            return jobId;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to schedule: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void unschedule(Id configId) {
        try {
            MAS_Configuration__c c = [
                SELECT Scheduled_Job_Id__c FROM MAS_Configuration__c WHERE Id = :configId LIMIT 1
            ];
            if (String.isNotBlank(c.Scheduled_Job_Id__c)) {
                try {
                    System.abortJob(c.Scheduled_Job_Id__c);
                } catch (Exception ignored) {
                    // Job may already be gone; clearing the stored Id is enough.
                }
            }
            update new MAS_Configuration__c(Id = configId, Scheduled_Job_Id__c = null);
        } catch (Exception e) {
            throw new AuraHandledException('Unable to unschedule: ' + e.getMessage());
        }
    }

    // ---------------------------------------------------------------------
    // CRUD helpers for the wizard
    // ---------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static MAS_Configuration__c getConfig(Id configId) {
        return [
            SELECT Id, Name, Description__c, Developer_Name__c, Active__c, Batch_Size__c,
                   Source_SOQL_Query__c, Target_Type__c, Target_Action_Name__c,
                   Schedule_Type__c, Schedule_Cron__c, Scheduled_Job_Id__c,
                   Last_Run_Status__c, Last_Run_Completed_Date__c
            FROM MAS_Configuration__c
            WHERE Id = :configId
            LIMIT 1
        ];
    }

    @AuraEnabled
    public static Id saveConfig(MAS_Configuration__c config) {
        try {
            upsert config;
            return config.Id;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to save configuration: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<MAS_Field_Mapping__c> getMappings(Id configId) {
        return [
            SELECT Id, Source_Field_Name__c, Target_Parameter_Name__c, Is_Literal__c
            FROM MAS_Field_Mapping__c
            WHERE Configuration__c = :configId
            ORDER BY Name
        ];
    }

    /**
     * Replaces the field mappings for a configuration with the supplied set.
     */
    @AuraEnabled
    public static void saveMappings(Id configId, List<MAS_Field_Mapping__c> mappings) {
        try {
            delete [SELECT Id FROM MAS_Field_Mapping__c WHERE Configuration__c = :configId];
            if (mappings != null && !mappings.isEmpty()) {
                List<MAS_Field_Mapping__c> toInsert = new List<MAS_Field_Mapping__c>();
                for (MAS_Field_Mapping__c m : mappings) {
                    toInsert.add(new MAS_Field_Mapping__c(
                        Configuration__c = configId,
                        Source_Field_Name__c = m.Source_Field_Name__c,
                        Target_Parameter_Name__c = m.Target_Parameter_Name__c,
                        Is_Literal__c = m.Is_Literal__c
                    ));
                }
                insert toInsert;
            }
        } catch (Exception e) {
            throw new AuraHandledException('Unable to save mappings: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<MAS_Log__c> getLogs(Id configId) {
        return [
            SELECT Id, Name, Message_Type__c, Message__c, Long_Message__c,
                   Total_Records__c, Processed_Records__c, Failed_Records__c,
                   Batch_Success_Percentage__c, Timestamp__c
            FROM MAS_Log__c
            WHERE Configuration__c = :configId
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------
    /**
     * Extracts top-level column expressions from a SELECT clause, ignoring
     * commas inside nested subqueries / function calls.
     */
    @TestVisible
    private static List<String> parseSelectColumns(String soql) {
        List<String> columns = new List<String>();
        String lower = soql.toLowerCase();
        Integer selectIdx = lower.indexOf('select ');
        Integer fromIdx = findTopLevelFrom(soql);
        if (selectIdx < 0 || fromIdx < 0) {
            return columns;
        }
        String clause = soql.substring(selectIdx + 7, fromIdx);
        Integer depth = 0;
        String current = '';
        for (Integer i = 0; i < clause.length(); i++) {
            String ch = clause.substring(i, i + 1);
            if (ch == '(') {
                depth++;
            } else if (ch == ')') {
                depth--;
            }
            if (ch == ',' && depth == 0) {
                addColumn(columns, current);
                current = '';
            } else {
                current += ch;
            }
        }
        addColumn(columns, current);
        return columns;
    }

    private static void addColumn(List<String> columns, String raw) {
        String col = raw.trim();
        // Skip subqueries; only simple/relationship field paths are previewable.
        if (String.isNotBlank(col) && !col.startsWith('(')) {
            columns.add(col);
        }
    }

    private static Integer findTopLevelFrom(String soql) {
        String lower = soql.toLowerCase();
        Integer depth = 0;
        for (Integer i = 0; i < lower.length() - 5; i++) {
            String ch = lower.substring(i, i + 1);
            if (ch == '(') {
                depth++;
            } else if (ch == ')') {
                depth--;
            } else if (depth == 0 && lower.substring(i, i + 6) == ' from ') {
                return i;
            }
        }
        return -1;
    }

    @TestVisible
    private static Object getFieldValue(SObject record, String fieldPath) {
        if (String.isBlank(fieldPath) || record == null) {
            return null;
        }
        try {
            if (!fieldPath.contains('.')) {
                return record.get(fieldPath);
            }
            List<String> parts = fieldPath.split('\\.');
            SObject current = record;
            for (Integer i = 0; i < parts.size() - 1; i++) {
                current = current.getSObject(parts[i]);
                if (current == null) {
                    return null;
                }
            }
            return current.get(parts[parts.size() - 1]);
        } catch (Exception e) {
            return null;
        }
    }
}
