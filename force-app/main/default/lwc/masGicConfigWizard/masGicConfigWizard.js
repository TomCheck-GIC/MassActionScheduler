import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

// Apex controller methods (exact shapes provided by the package controller)
import getConfig from '@salesforce/apex/MAS_GIC_ConfigController.getConfig';
import getMappings from '@salesforce/apex/MAS_GIC_ConfigController.getMappings';
import getActiveFlows from '@salesforce/apex/MAS_GIC_ConfigController.getActiveFlows';
import getInvocableApexClasses from '@salesforce/apex/MAS_GIC_ConfigController.getInvocableApexClasses';
import getActionInputs from '@salesforce/apex/MAS_GIC_ConfigController.getActionInputs';
import previewSource from '@salesforce/apex/MAS_GIC_ConfigController.previewSource';
import runNow from '@salesforce/apex/MAS_GIC_ConfigController.runNow';
import saveConfig from '@salesforce/apex/MAS_GIC_ConfigController.saveConfig';
import saveMappings from '@salesforce/apex/MAS_GIC_ConfigController.saveMappings';
import saveSchedule from '@salesforce/apex/MAS_GIC_ConfigController.saveSchedule';
import unschedule from '@salesforce/apex/MAS_GIC_ConfigController.unschedule';

// Target type options
const TARGET_FLOW = 'Flow';
const TARGET_APEX = 'Apex';

// Schedule type options
const SCHEDULE_MANUAL = 'Manual';
const SCHEDULE_SCHEDULED = 'Scheduled';

// Schedule frequency options (drive the friendly cron builder)
const FREQUENCY_HOURLY = 'hourly';
const FREQUENCY_DAILY = 'daily';
const FREQUENCY_WEEKLY = 'weekly';
const FREQUENCY_MONTHLY = 'monthly';
const FREQUENCY_CUSTOM = 'custom';

const DAY_OF_WEEK_OPTIONS = [
    { label: 'Mon', value: 'MON' },
    { label: 'Tue', value: 'TUE' },
    { label: 'Wed', value: 'WED' },
    { label: 'Thu', value: 'THU' },
    { label: 'Fri', value: 'FRI' },
    { label: 'Sat', value: 'SAT' },
    { label: 'Sun', value: 'SUN' }
];

const DAY_OF_MONTH_OPTIONS = [
    ...Array.from({ length: 28 }, (_, i) => ({ label: String(i + 1), value: String(i + 1) })),
    { label: 'Last day of month', value: 'L' }
];

const VALUE_TYPE_FIELD = 'field';
const VALUE_TYPE_LITERAL = 'literal';

const VALUE_TYPE_OPTIONS = [
    { label: 'Field from Query', value: VALUE_TYPE_FIELD },
    { label: 'Literal Value', value: VALUE_TYPE_LITERAL }
];

/**
 * Extracts the top-level field list out of a SOQL SELECT clause, e.g.
 * "SELECT Id, Name, Account.Name, (SELECT Id FROM Contacts) FROM Contact"
 * -> ['Id', 'Name', 'Account.Name']. Child subqueries are parenthesized and
 * return record lists rather than scalar values, so they're excluded.
 * Comma-splitting tracks paren depth so subquery/function-call commas
 * (e.g. inside a child relationship query) don't split the field list.
 */
function parseSoqlSelectFields(soql) {
    if (!soql) {
        return [];
    }
    const match = /^\s*select\s+([\s\S]*?)\s+from\s+/i.exec(soql);
    if (!match) {
        return [];
    }
    const fieldsPart = match[1];
    const fields = [];
    let depth = 0;
    let current = '';
    for (const ch of fieldsPart) {
        if (ch === '(') {
            depth += 1;
        } else if (ch === ')') {
            depth -= 1;
        }
        if (ch === ',' && depth === 0) {
            fields.push(current.trim());
            current = '';
        } else {
            current += ch;
        }
    }
    if (current.trim()) {
        fields.push(current.trim());
    }
    return fields.filter((f) => f && !f.startsWith('(')).map((f) => f.replace(/\s+/g, ' '));
}

export default class MasGicConfigWizard extends LightningElement {
    /** MAS_GIC_Configuration__c record Id (populated on a Record Page). */
    @api recordId;

    // ----- Reactive state -----
    @track config = {}; // mutable copy of the MAS_GIC_Configuration__c sObject
    @track mappings = []; // working list of field-mapping rows
    @track flowOptions = []; // combobox options built from getActiveFlows
    @track apexActionOptions = []; // combobox options built from getInvocableApexClasses
    @track targetParams = []; // params returned by getActionInputs
    @track previewColumns = []; // datatable columns for the SOQL preview
    @track previewRows = []; // datatable rows for the SOQL preview

    /** Friendly schedule builder state; Schedule_Cron__c remains the persisted source of truth. */
    @track scheduleBuilder = {
        frequency: FREQUENCY_DAILY,
        hour: 6,
        minute: 0,
        daysOfWeek: ['MON'],
        dayOfMonth: '1'
    };

    isLoading = true;
    isPreviewLoading = false;
    isInputsLoading = false;

    // Tracks whether each initial @wire load has resolved (data or error),
    // so isLoading can drop once all four have reported in.
    _flowsReady = false;
    _apexActionsReady = false;
    _configReady = false;
    _mappingsReady = false;

    // Raw @wire results for getConfig/getMappings, kept so handleSave can
    // force a genuine server refetch (refreshApex) after saving. Without
    // this, the cacheable wires can replay their pre-save cached value on a
    // later re-subscription and silently overwrite the just-saved local
    // state with stale data.
    _configWireResult;
    _mappingsWireResult;

    // Radio option definitions ----------------------------------------------
    targetTypeOptions = [
        { label: 'Flow', value: TARGET_FLOW },
        { label: 'Apex', value: TARGET_APEX }
    ];

    scheduleTypeOptions = [
        { label: 'Manual (run on demand)', value: SCHEDULE_MANUAL },
        { label: 'Scheduled', value: SCHEDULE_SCHEDULED }
    ];

    scheduleFrequencyOptions = [
        { label: 'Hourly', value: FREQUENCY_HOURLY },
        { label: 'Daily', value: FREQUENCY_DAILY },
        { label: 'Weekly', value: FREQUENCY_WEEKLY },
        { label: 'Monthly', value: FREQUENCY_MONTHLY },
        { label: 'Custom (advanced)', value: FREQUENCY_CUSTOM }
    ];

    dayOfWeekOptions = DAY_OF_WEEK_OPTIONS;
    dayOfMonthOptions = DAY_OF_MONTH_OPTIONS;

    cronPresets = [
        { label: 'Every hour', cron: '0 0 * * * ?' },
        { label: 'Daily 6am', cron: '0 0 6 * * ?' },
        { label: 'Weekly Mon 6am', cron: '0 0 6 ? * MON' }
    ];

    // ----- Lifecycle -------------------------------------------------------
    connectedCallback() {
        if (!this.recordId) {
            // New record: nothing to wire in, so set defaults synchronously.
            // (@wire(getConfig)/@wire(getMappings) below never fire without a recordId.)
            this.config = {
                Active__c: true,
                Batch_Size__c: 50,
                Target_Type__c: TARGET_FLOW,
                Schedule_Type__c: SCHEDULE_MANUAL
            };
            this.applyCronToBuilder();
            this._configReady = true;
            this._mappingsReady = true;
            this.checkInitialLoadComplete();
        }
    }

    // ----- Wired reads (reactive, read-only) --------------------------------
    @wire(getActiveFlows)
    wiredFlows({ data, error }) {
        if (data) {
            this.buildFlowOptions(data);
        } else if (error) {
            this.showError('Failed to load flows', error);
        }
        this._flowsReady = true;
        this.checkInitialLoadComplete();
    }

    @wire(getInvocableApexClasses)
    wiredApexActions({ data, error }) {
        if (data) {
            this.buildApexActionOptions(data);
        } else if (error) {
            this.showError('Failed to load Apex actions', error);
        }
        this._apexActionsReady = true;
        this.checkInitialLoadComplete();
    }

    @wire(getConfig, { configId: '$recordId' })
    wiredConfig(result) {
        this._configWireResult = result;
        const { data, error } = result;
        if (data) {
            // Copy sObject into a mutable plain object; the wizard edits this
            // locally, it does not mutate the wired value directly.
            this.config = { ...data };
            this.applyCronToBuilder();
            if (this.config.Target_Type__c && this.config.Target_Action_Name__c) {
                this.loadActionInputs();
            }
        } else if (error) {
            this.showError('Failed to load configuration', error);
        }
        this._configReady = true;
        this.checkInitialLoadComplete();
    }

    @wire(getMappings, { configId: '$recordId' })
    wiredMappings(result) {
        this._mappingsWireResult = result;
        const { data, error } = result;
        if (data) {
            this.mappings = this.relabelMappings(data.map((m, i) => this.toMappingRow(m, i)));
        } else if (error) {
            this.showError('Failed to load field mappings', error);
        }
        this._mappingsReady = true;
        this.checkInitialLoadComplete();
    }

    checkInitialLoadComplete() {
        if (this._flowsReady && this._apexActionsReady && this._configReady && this._mappingsReady) {
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

    buildApexActionOptions(classes) {
        this.apexActionOptions = (classes || []).map((c) => ({
            label: c.label,
            value: c.apiName
        }));
    }

    toMappingRow(m, index) {
        const isLiteral = !!m.Is_Literal__c;
        return {
            key: m.Id || `new-${index}-${Date.now()}`,
            Id: m.Id,
            Source_Field_Name__c: m.Source_Field_Name__c,
            Target_Parameter_Name__c: m.Target_Parameter_Name__c,
            Is_Literal__c: isLiteral,
            valueType: isLiteral ? VALUE_TYPE_LITERAL : VALUE_TYPE_FIELD
        };
    }

    /** Recomputes each row's screen-reader delete label to match its current position. */
    relabelMappings(rows) {
        return rows.map((row, i) => ({ ...row, deleteLabel: `Delete mapping row ${i + 1}` }));
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

    /** Preview column API names, used as a fallback source-field hint. */
    get previewColumnHints() {
        return this.previewColumns.map((c) => c.fieldName);
    }

    /** Value Type options (Field from Query vs. Literal Value) for each mapping row. */
    get valueTypeOptions() {
        return VALUE_TYPE_OPTIONS;
    }

    /**
     * Combobox options for the Source Field cell: fields parsed live out of the
     * SELECT clause of Source_SOQL_Query__c, falling back to/merging with any
     * columns already returned by a Preview run (covers queries the parser can't
     * fully handle, e.g. TYPEOF or multi-clause WHERE with an unmatched FROM).
     */
    get sourceFieldOptions() {
        const parsed = parseSoqlSelectFields(this.config.Source_SOQL_Query__c);
        const seen = new Set();
        const merged = [];
        [...parsed, ...this.previewColumnHints].forEach((f) => {
            if (f && !seen.has(f)) {
                seen.add(f);
                merged.push(f);
            }
        });
        return merged.map((f) => ({ label: f, value: f }));
    }

    get showSchedulePicker() {
        return this.scheduleBuilder.frequency !== FREQUENCY_HOURLY
            && this.scheduleBuilder.frequency !== FREQUENCY_CUSTOM;
    }

    get isWeeklyFrequency() {
        return this.scheduleBuilder.frequency === FREQUENCY_WEEKLY;
    }

    get isMonthlyFrequency() {
        return this.scheduleBuilder.frequency === FREQUENCY_MONTHLY;
    }

    get isCustomFrequency() {
        return this.scheduleBuilder.frequency === FREQUENCY_CUSTOM;
    }

    /** HH:MM:SS value for lightning-input type="time", derived from the builder's hour/minute. */
    get scheduleTimeValue() {
        const pad = (n) => String(n).padStart(2, '0');
        return `${pad(this.scheduleBuilder.hour)}:${pad(this.scheduleBuilder.minute)}:00.000`;
    }

    get hasLastRun() {
        return !!this.config.Last_Run_Status__c;
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

    handleApexActionSelect(event) {
        this.config = { ...this.config, Target_Action_Name__c: event.detail.value };
        this.loadActionInputs();
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
        this.mappings = this.relabelMappings([
            ...this.mappings,
            {
                key: `new-${this.mappings.length}-${Date.now()}`,
                Id: null,
                Source_Field_Name__c: '',
                Target_Parameter_Name__c: '',
                Is_Literal__c: false,
                valueType: VALUE_TYPE_FIELD
            }
        ]);
    }

    handleDeleteMapping(event) {
        const key = event.target.dataset.key;
        this.mappings = this.relabelMappings(this.mappings.filter((m) => m.key !== key));
    }

    /** Toggles a row between picking a field off the query and typing a literal value. */
    handleValueTypeChange(event) {
        const key = event.target.dataset.key;
        const valueType = event.detail.value;
        this.mappings = this.mappings.map((m) =>
            m.key === key
                ? { ...m, valueType, Is_Literal__c: valueType === VALUE_TYPE_LITERAL, Source_Field_Name__c: '' }
                : m
        );
    }

    handleMappingChange(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        // lightning-combobox reports its value via event.detail; lightning-input via event.target.
        const value = event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
        this.mappings = this.mappings.map((m) =>
            m.key === key ? { ...m, [field]: value } : m
        );
    }

    // ----- Schedule builder --------------------------------------------------
    /** Builds a Quartz cron expression from the current friendly builder state. */
    buildCronFromBuilder() {
        const { frequency, hour, minute, daysOfWeek, dayOfMonth } = this.scheduleBuilder;
        const h = Number.isInteger(hour) ? hour : 0;
        const m = Number.isInteger(minute) ? minute : 0;
        switch (frequency) {
            case FREQUENCY_HOURLY:
                return '0 0 * * * ?';
            case FREQUENCY_DAILY:
                return `0 ${m} ${h} * * ?`;
            case FREQUENCY_WEEKLY: {
                const days = daysOfWeek && daysOfWeek.length ? daysOfWeek.join(',') : 'MON';
                return `0 ${m} ${h} ? * ${days}`;
            }
            case FREQUENCY_MONTHLY:
                return `0 ${m} ${h} ${dayOfMonth || '1'} * ?`;
            default:
                return this.config.Schedule_Cron__c;
        }
    }

    /** Parses a Quartz cron expression back into friendly builder state, falling back to Custom. */
    parseCronToBuilder(cron) {
        const defaults = {
            frequency: FREQUENCY_DAILY,
            hour: 6,
            minute: 0,
            daysOfWeek: ['MON'],
            dayOfMonth: '1'
        };
        if (!cron) {
            return defaults;
        }
        const parts = cron.trim().split(/\s+/);
        if (parts.length !== 6) {
            return { ...defaults, frequency: FREQUENCY_CUSTOM };
        }
        const [sec, min, hr, dom, mon, dow] = parts;
        const isNum = (v) => /^\d+$/.test(v);

        if (sec === '0' && min === '0' && hr === '*' && dom === '*' && mon === '*' && dow === '?') {
            return { ...defaults, frequency: FREQUENCY_HOURLY };
        }
        if (sec === '0' && isNum(min) && isNum(hr) && dom === '*' && mon === '*' && dow === '?') {
            return { ...defaults, frequency: FREQUENCY_DAILY, hour: Number(hr), minute: Number(min) };
        }
        if (sec === '0' && isNum(min) && isNum(hr) && dom === '?' && mon === '*' && dow !== '?') {
            const days = dow.split(',').map((d) => d.trim().toUpperCase());
            return { ...defaults, frequency: FREQUENCY_WEEKLY, hour: Number(hr), minute: Number(min), daysOfWeek: days };
        }
        if (sec === '0' && isNum(min) && isNum(hr) && (dom === 'L' || isNum(dom)) && mon === '*' && dow === '?') {
            return { ...defaults, frequency: FREQUENCY_MONTHLY, hour: Number(hr), minute: Number(min), dayOfMonth: dom };
        }
        return { ...defaults, frequency: FREQUENCY_CUSTOM };
    }

    /** Re-derives builder state from the loaded record's cron, then normalizes the cron to match. */
    applyCronToBuilder() {
        this.scheduleBuilder = this.parseCronToBuilder(this.config.Schedule_Cron__c);
        this.recomputeCron();
    }

    /** Regenerates Schedule_Cron__c from the builder, unless the user is in Custom (raw) mode. */
    recomputeCron() {
        if (this.scheduleBuilder.frequency === FREQUENCY_CUSTOM) {
            return;
        }
        this.config = { ...this.config, Schedule_Cron__c: this.buildCronFromBuilder() };
    }

    handleFrequencyChange(event) {
        this.scheduleBuilder = { ...this.scheduleBuilder, frequency: event.detail.value };
        this.recomputeCron();
    }

    handleScheduleTimeChange(event) {
        const [hh, mm] = event.target.value.split(':');
        this.scheduleBuilder = { ...this.scheduleBuilder, hour: Number(hh), minute: Number(mm) };
        this.recomputeCron();
    }

    handleDaysOfWeekChange(event) {
        this.scheduleBuilder = { ...this.scheduleBuilder, daysOfWeek: event.detail.value };
        this.recomputeCron();
    }

    handleDayOfMonthChange(event) {
        this.scheduleBuilder = { ...this.scheduleBuilder, dayOfMonth: event.detail.value };
        this.recomputeCron();
    }

    // ----- Schedule actions ------------------------------------------------
    handleCronPreset(event) {
        const cron = event.target.dataset.cron;
        this.config = { ...this.config, Schedule_Cron__c: cron };
    }

    // ----- Footer actions --------------------------------------------------
    /** Reports validity on required/bounded fields; returns false and stops the save if any fail. */
    isFormValid() {
        const fields = this.template.querySelectorAll('.validated-field');
        let allValid = true;
        fields.forEach((field) => {
            if (!field.reportValidity()) {
                allValid = false;
            }
        });
        return allValid;
    }

    async handleSave() {
        if (!this.isFormValid()) {
            return;
        }
        this.isLoading = true;
        try {
            // Snapshot every value this save needs from local state up front,
            // before any awaited Apex call. The getConfig/getMappings wires are
            // cacheable, and a DML against this record can cause them to replay
            // their pre-edit cached value into this.config/this.mappings while
            // this save's own await chain is still in flight (proven live: an
            // unprompted getActionInputs call fired between the saveSchedule and
            // saveMappings calls below, which only happens if wiredConfig
            // re-ran). Re-reading this.config/this.mappings after an await risks
            // building a later call (saveSchedule, saveMappings) from that
            // clobbered stale data instead of what the user actually just
            // edited - silently reverting/failing the save instead of just
            // mis-displaying it.
            const payload = { ...this.config };
            if (this.recordId) {
                payload.Id = this.recordId;
            }
            const scheduleType = payload.Schedule_Type__c;
            const scheduleCron = payload.Schedule_Cron__c;
            const hadScheduledJob = payload.Scheduled_Job_Id__c;
            const mappingPayload = this.mappings.map((m) => ({
                Source_Field_Name__c: m.Source_Field_Name__c,
                Target_Parameter_Name__c: m.Target_Parameter_Name__c,
                Is_Literal__c: !!m.Is_Literal__c
            }));

            const savedId = await saveConfig({ config: payload });
            this.recordId = this.recordId || savedId;
            this.config = { ...this.config, Id: savedId };

            // Reconcile the actual scheduled batch job with whatever schedule
            // state was just saved. Save is the single action that both
            // persists the configuration and (un)schedules its job - there's
            // no separate "Save Schedule" step that can drift out of sync
            // with a Schedule_Cron__c the user just edited but never actually
            // applied to the real CronTrigger.
            if (scheduleType === SCHEDULE_SCHEDULED) {
                if (!scheduleCron) {
                    this.showToast('No cron', 'Enter or pick a cron expression before saving a scheduled configuration.', 'warning');
                } else {
                    const jobId = await saveSchedule({
                        configId: savedId,
                        cronExpression: scheduleCron
                    });
                    this.config = { ...this.config, Scheduled_Job_Id__c: jobId };
                }
            } else if (hadScheduledJob) {
                await unschedule({ configId: savedId });
                this.config = { ...this.config, Scheduled_Job_Id__c: null };
            }

            // Persist mappings against the (now guaranteed) config Id.
            await saveMappings({ configId: savedId, mappings: mappingPayload });

            // The getConfig/getMappings wires are cacheable, and a later
            // re-subscription (e.g. the record page re-rendering this
            // component after the DML above) can replay their pre-save
            // cached value, clobbering the local state just set above with
            // stale data. Forcing a real refetch here - as the last step of
            // save - guarantees this.config/this.mappings end up reflecting
            // what the server actually has, regardless of any such replay.
            await Promise.all(
                [this._configWireResult, this._mappingsWireResult]
                    .filter(Boolean)
                    .map((wired) => refreshApex(wired))
            );

            this.showToast('Saved', 'Configuration, schedule, and mappings saved.', 'success');
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