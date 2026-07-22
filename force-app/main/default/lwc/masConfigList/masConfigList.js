import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

/**
 * Entry-point component for the Mass Action Scheduler app. "New Configuration"
 * embeds masConfigWizard inline (with no recordId, its supported "create" mode)
 * rather than the bare-bones standard quick-create modal, so record creation
 * gets the full editor (SOQL, target, mappings, schedule) up front.
 */
export default class MasConfigList extends NavigationMixin(LightningElement) {
    showWizard = false;

    handleNew() {
        this.showWizard = true;
    }

    handleCancelNew() {
        this.showWizard = false;
    }

    handleWizardSaved(event) {
        this.showWizard = false;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                objectApiName: 'MAS_Configuration__c',
                recordId: event.detail.recordId,
                actionName: 'view'
            }
        });
    }

    handleViewAll() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'MAS_Configuration__c',
                actionName: 'list'
            },
            state: {
                filterName: 'Recent'
            }
        });
    }
}
