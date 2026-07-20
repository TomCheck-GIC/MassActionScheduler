import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// Apex controller methods (exact shapes provided by the package controller)
import getConfig from '@salesforce/apex/MAS_ConfigController.getConfig';
import getMappings from '@salesforce/apex/MAS_ConfigController.getMappings';
import getActiveFlows from '@salesforce/apex/MAS_ConfigController.getActiveFlows';
import getActionInputs from '@salesforce/apex/MAS_ConfigController.getActionInputs';
import previewSource from '@salesforce/apex/MAS_ConfigController.previewSource';
import runNow from '@salesforce/apex/MAS_ConfigController.runNow';
import saveConfig from '@salesforce/apex/MAS_ConfigController.saveConfig';
import saveMappings from '@salesforce/apex/MAS_ConfigController.saveMappings';
import saveSchedule from '@salesforce/apex/MAS_ConfigController.saveSchedule';
import unschedule from '@salesforce/apex/MAS_ConfigController.unschedule';

// Target type options
const TARGET_FLOW = 'Flow';
const TARGET_APEX = 'Apex';

// Schedule type options
const SCHEDULE_MANUAL = 'Manual';
const SCHEDULE_SCHEDULED = 'Scheduled';

export default class MasConfigWizard extends LightningElement {
    /** MAS_Configuration__c record Id (populated on a Record Page). */
    @api recordId;

    // ----- Reactive state -----
    @track config = {}; // mutable copy of the MAS_Configuration__c sObject
    @track mappings = []; // working list of field-mapping rows
    @track flowOptions = []; // combobox options built from getActiveFlows
    @track targetParams = []; // params returned by getActionInputs
    @track previewColumns = []; // datatable columns for the SOQL preview
    @track previewRows = []; // datatable rows for the SOQL preview

    isLoading = false;
    isPreviewLoading = false;
    isInputsLoading = false;

    // Radio option definitions ----------------------------------------------
    targetTypeOptions = [
        { label: 'Flow', value: TARGET_FLOW },
        { label: 'Apex', value: TARGET_APEX }
    ];

    scheduleTypeOptions = [
        { label: 'Manual (run on demand)', value: SCHEDULE_MANUAL },
        { label: 'Scheduled', value: SCHEDULE_SCHEDULED }
    ];

    cronPresets = [
        { label: 'Every hour', cron: '0 0 * * * ?' },
        { label: 'Daily 6am', cron: '0 0 6 * * ?' },
        { label: 'Weekly Mon 6am', cron: '0 0 6 ? * MON' }
    ];

    // ----- Lifecycle -------------------------------------------------------
    connectedCallback() {
        this.loadEverything();
    }

    async loadEverything() {
        this.isLoading = true;
        try {
            // Active flows do not depend on the record, always load them.
            this.buildFlowOptions(await getActiveFlows());

            if (this.recordId) {
                const [cfg, maps] = await Promise.all([
                    getConfig({ configId: this.recordId }),
                    getMappings({ configId: this.recordId })
                ]);
                // Copy sObject into a mutable plain object.
                this.config = cfg ? { ...cfg } : {};
                this.mappings = (maps || []).map((m, i) => this.toMappingRow(m, i));

                // If a target action is already configured, load its inputs.
                if (this.config.Target_Type__c && this.config.Target_Action_Name__c) {
                    await this.loadActionInputs();
                }
            } else {
                // New record defaults.
                this.config = {
                    Active__c: true,
                    Batch_Size__c: 50,
                    Target_Type__c: TARGET_FLOW,
                    Schedule_Type__c: SCHEDULE_MANUAL
                };
            }
        } catch (error) {
            this.showError('Failed to load configuration', error);
        } finally {
            this.isLoading = false;
        }
    }

    // ----- Helpers ---------------------------------------------------------
    buildFlowOptions(flows) {
        this.flowOptions = (flows || []).map((f) => ({
            label: f.label,
            value: f.apiName
        }));
    }

    toMappingRow(m, index) {
        return {
            key: m.Id || `new-${index}-${Date.now()}`,
            Id: m.Id,
            Source_Field_Name__c: m.Source_Field_Name__c,
            Target_Parameter_Name__c: m.Target_Parameter_Name__c,
            Is_Literal__c: !!m.Is_Literal__c
        };
    }

    // ----- Computed getters ------------------------------------------------
    get isFlowTarget() {
        return this.config.Target_Type__c === TARGET_FLOW;
    }

    get isApexTarget() {
        return this.config.Target_Type__c === TARGET_APEX;
    }

    get isScheduled() {
        return this.config.Schedule_Type__c === SCHEDULE_SCHEDULED;
    }

    get hasScheduledJob() {
        return !!this.config.Scheduled_Job_Id__c;
    }

    get noScheduledJob() {
        return !this.config.Scheduled_Job_Id__c;
    }

    get hasPreview() {
        return this.previewColumns.length > 0;
    }

    /** Options for the Target Parameter combobox in mapping rows. */
    get targetParamOptions() {
        return this.targetParams.map((p) => ({
            label: `${p.label} (${p.dataType})${p.required ? ' *' : ''}`,
            value: p.name
        }));
    }

    /** Preview column API names, exposed for the source-field datalist hint. */
    get previewColumnHints() {
        return this.previewColumns.map((c) => c.fieldName);
    }

    get lastRunSummary() {
        if (!this.config.Last_Run_Status__c) {
            return null;
        }
        const when = this.config.Last_Run_Completed_Date__c
            ? ` on ${this.config.Last_Run_Completed_Date__c}`
            : '';
        return `${this.config.Last_Run_Status__c}${when}`;
    }

    // ----- Basic field handlers -------------------------------------------
    handleFieldChange(event) {
        const field = event.target.dataset.field;
        let value = event.target.value;
        if (event.target.type === 'checkbox' || event.target.type === 'toggle') {
            value = event.target.checked;
        }
        this.config = { ...this.config, [field]: value };
    }

    handleActiveToggle(event) {
        this.config = { ...this.config, Active__c: event.target.checked };
    }

    handleTargetTypeChange(event) {
        this.config = {
            ...this.config,
            Target_Type__c: event.detail.value,
            // Reset the action name when switching target types.
            Target_Action_Name__c: null
        };
        this.targetParams = [];
    }

    handleFlowSelect(event) {
        this.config = { ...this.config, Target_Action_Name__c: event.detail.value };
        this.loadActionInputs();
    }

    handleApexClassChange(event) {
        this.config = { ...this.config, Target_Action_Name__c: event.target.value };
    }

    handleScheduleTypeChange(event) {
        this.config = { ...this.config, Schedule_Type__c: event.detail.value };
    }

    // ----- Target inputs ---------------------------------------------------
    async loadActionInputs() {
        if (!this.config.Target_Type__c || !this.config.Target_Action_Name__c) {
            this.showToast('Missing target', 'Choose a target action first.', 'warning');
            return;
        }
        this.isInputsLoading = true;
        try {
            const params = await getActionInputs({
                targetType: this.config.Target_Type__c,
                actionName: this.config.Target_Action_Name__c
            });
            this.targetParams = params || [];
        } catch (error) {
            this.showError('Failed to load target inputs', error);
        } finally {
            this.isInputsLoading = false;
        }
    }

    handleLoadInputs() {
        this.loadActionInputs();
    }

    // ----- SOQL preview ----------------------------------------------------
    async handlePreview() {
        const soql = this.config.Source_SOQL_Query__c;
        if (!soql) {
            this.showToast('No query', 'Enter a SOQL query to preview.', 'warning');
            return;
        }
        this.isPreviewLoading = true;
        try {
            const result = await previewSource({ soql });
            this.previewColumns = (result.columns || []).map((c) => ({
                label: c,
                fieldName: c,
                wrapText: false
            }));
            // Rows already come as plain objects keyed by column name.
            this.previewRows = (result.rows || []).map((r, i) => ({
                _key: `row-${i}`,
                ...r
            }));
            this.showToast(
                'Preview complete',
                `${result.totalPreviewed} record(s) previewed.`,
                'success'
            );
        } catch (error) {
            this.showError('Preview failed', error);
        } finally {
            this.isPreviewLoading = false;
        }
    }

    // ----- Field mappings grid --------------------------------------------
    handleAddMapping() {
        this.mappings = [
            ...this.mappings,
            {
                key: `new-${this.mappings.length}-${Date.now()}`,
                Id: null,
                Source_Field_Name__c: '',
                Target_Parameter_Name__c: '',
                Is_Literal__c: false
            }
        ];
    }

    handleDeleteMapping(event) {
        const key = event.target.dataset.key;
        this.mappings = this.mappings.filter((m) => m.key !== key);
    }

    handleMappingChange(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        let value = event.target.value;
        if (event.target.type === 'checkbox') {
            value = event.target.checked;
        }
        // combobox uses event.detail.value
        if (event.detail && event.detail.value !== undefined && field === 'Target_Parameter_Name__c') {
            value = event.detail.value;
        }
        this.mappings = this.mappings.map((m) =>
            m.key === key ? { ...m, [field]: value } : m
        );
    }

    // ----- Schedule actions ------------------------------------------------
    handleCronPreset(event) {
        const cron = event.target.dataset.cron;
        this.config = { ...this.config, Schedule_Cron__c: cron };
    }

    async handleSaveSchedule() {
        if (!this.recordId) {
            this.showToast('Save first', 'Save the configuration before scheduling.', 'warning');
            return;
        }
        if (!this.config.Schedule_Cron__c) {
            this.showToast('No cron', 'Enter or pick a cron expression.', 'warning');
            return;
        }
        this.isLoading = true;
        try {
            const jobId = await saveSchedule({
                configId: this.recordId,
                cronExpression: this.config.Schedule_Cron__c
            });
            this.config = { ...this.config, Scheduled_Job_Id__c: jobId };
            this.showToast('Scheduled', `Job Id: ${jobId}`, 'success');
        } catch (error) {
            this.showError('Failed to schedule', error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleUnschedule() {
        if (!this.recordId) {
            return;
        }
        this.isLoading = true;
        try {
            await unschedule({ configId: this.recordId });
            this.config = { ...this.config, Scheduled_Job_Id__c: null };
            this.showToast('Unscheduled', 'The scheduled job was removed.', 'success');
        } catch (error) {
            this.showError('Failed to unschedule', error);
        } finally {
            this.isLoading = false;
        }
    }

    // ----- Footer actions --------------------------------------------------
    async handleSave() {
        this.isLoading = true;
        try {
            // Build a plain object matching MAS_Configuration__c field API names.
            const payload = { ...this.config };
            if (this.recordId) {
                payload.Id = this.recordId;
            }
            const savedId = await saveConfig({ config: payload });
            this.recordId = this.recordId || savedId;
            this.config = { ...this.config, Id: savedId };

            // Persist mappings against the (now guaranteed) config Id.
            const mappingPayload = this.mappings.map((m) => ({
                Source_Field_Name__c: m.Source_Field_Name__c,
                Target_Parameter_Name__c: m.Target_Parameter_Name__c,
                Is_Literal__c: !!m.Is_Literal__c
            }));
            await saveMappings({ configId: savedId, mappings: mappingPayload });

            this.showToast('Saved', 'Configuration and mappings saved.', 'success');
            // Notify any parent / enable record page refresh.
            this.dispatchEvent(new CustomEvent('saved', { detail: { recordId: savedId } }));
        } catch (error) {
            this.showError('Save failed', error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleRunNow() {
        if (!this.recordId) {
            this.showToast('Save first', 'Save the configuration before running.', 'warning');
            return;
        }
        this.isLoading = true;
        try {
            const jobId = await runNow({ configId: this.recordId });
            this.showToast('Run started', `Batch job Id: ${jobId}`, 'success');
        } catch (error) {
            this.showError('Run failed', error);
        } finally {
            this.isLoading = false;
        }
    }

    // ----- Toast helpers ---------------------------------------------------
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    showError(title, error) {
        const message =
            (error && error.body && error.body.message) ||
            (error && error.message) ||
            'Unknown error';
        this.dispatchEvent(
            new ShowToastEvent({ title, message, variant: 'error' })
        );
    }
}
