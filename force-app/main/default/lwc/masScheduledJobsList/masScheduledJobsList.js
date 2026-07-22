import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getScheduledJobs from '@salesforce/apex/MAS_ConfigController.getScheduledJobs';

const COLUMNS = [
    { label: 'Job Name', fieldName: 'jobName', type: 'text' },
    {
        label: 'Configuration',
        fieldName: 'configUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'configName' }, target: '_self' }
    },
    { label: 'Runs', fieldName: 'scheduleDescription', type: 'text', wrapText: true },
    {
        label: 'Next Run',
        fieldName: 'nextFireTime',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    },
    { label: 'Status', fieldName: 'state', type: 'text' }
];

/**
 * Read-only summary of every currently-scheduled Mass Action configuration,
 * for the app's "Scheduled Jobs" tab (and reusable on the app home page).
 * Links to each configuration's record page rather than to Setup's Scheduled
 * Jobs list, since individual CronTrigger rows there don't have a navigable
 * detail page of their own.
 */
export default class MasScheduledJobsList extends LightningElement {
    columns = COLUMNS;
    jobs = [];
    isLoading = true;
    error;

    _wiredResult;

    @wire(getScheduledJobs)
    wiredJobs(result) {
        this._wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.jobs = data.map((job) => ({
                ...job,
                configUrl: `/lightning/r/MAS_Configuration__c/${job.configId}/view`
            }));
            this.error = undefined;
        } else if (error) {
            this.error = (error.body && error.body.message) || 'Unable to load scheduled jobs.';
            this.jobs = [];
        }
        this.isLoading = false;
    }

    get hasJobs() {
        return this.jobs.length > 0;
    }

    handleRefresh() {
        if (this._wiredResult) {
            this.isLoading = true;
            refreshApex(this._wiredResult).finally(() => {
                this.isLoading = false;
            });
        }
    }
}
