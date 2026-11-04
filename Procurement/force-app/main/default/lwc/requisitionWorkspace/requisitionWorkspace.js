import { LightningElement, api, track } from 'lwc';
import getRequisitionWithLines from '@salesforce/apex/RequisitionService.getRequisitionWithLines';
import saveRequisition from '@salesforce/apex/RequisitionService.saveRequisition';
import submitRequisitionForApproval from '@salesforce/apex/RequisitionService.submitRequisitionForApproval';

export default class RequisitionWorkspace extends LightningElement {
    @api recordId;
    @track requisition = {
        Request_Date__c: new Date().toISOString().split('T')[0],
        Priority__c: 'Normal',
        Source__c: 'Manual',
        Status__c: 'Draft'
    };
    @track lines = [];
    @track isLoading = false;
    @track isSaving = false;
    @track errorMessage = null;
    @track successMessage = null;
    @track isEditable = true;

    _lineCounter = 0;

    priorityOptions = [
        { label: 'Low', value: 'Low' },
        { label: 'Normal', value: 'Normal' },
        { label: 'High', value: 'High' },
        { label: 'Critical', value: 'Critical' }
    ];

    connectedCallback() {
        if (this.recordId) {
            this.loadRequisition();
        } else {
            this.addBlankLine();
        }
    }

    loadRequisition() {
        this.isLoading = true;
        getRequisitionWithLines({ requisitionId: this.recordId })
            .then(wrapper => {
                this.requisition = { ...wrapper.requisition };
                this.lines = wrapper.lines.map(l => ({ ...l, _key: l.Id, lineTotal: this.calcLineTotal(l) }));
                this.isEditable = wrapper.isEditable;
                this.isLoading = false;
            })
            .catch(err => {
                this.errorMessage = err.body ? err.body.message : 'Error loading requisition';
                this.isLoading = false;
            });
    }

    addBlankLine() {
        this._lineCounter++;
        this.lines = [...this.lines, {
            _key: 'new-' + this._lineCounter,
            Product__c: null,
            productName: '',
            Requested_Qty__c: 1,
            Estimated_Unit_Price__c: 0,
            Line_Notes__c: '',
            lineTotal: 0
        }];
    }

    handleAddLine() { this.addBlankLine(); }

    handleDeleteLine(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const updated = [...this.lines];
        updated.splice(idx, 1);
        this.lines = updated;
    }

    handleFieldChange(event) {
        const field = event.currentTarget.dataset.field;
        this.requisition = { ...this.requisition, [field]: event.target.value };
    }

    handleLineProductChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const updated = [...this.lines];
        updated[idx] = { ...updated[idx], Product__c: event.detail.recordId };
        this.lines = updated;
    }

    handleLineFieldChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const field = event.currentTarget.dataset.field;
        const updated = [...this.lines];
        updated[idx] = { ...updated[idx], [field]: event.target.value };
        updated[idx].lineTotal = this.calcLineTotal(updated[idx]);
        this.lines = updated;
    }

    calcLineTotal(line) {
        const qty = parseFloat(line.Requested_Qty__c) || 0;
        const price = parseFloat(line.Estimated_Unit_Price__c) || 0;
        return qty * price;
    }

    get estimatedTotal() {
        return this.lines.reduce((sum, l) => sum + (parseFloat(l.lineTotal) || 0), 0);
    }

    get isLocked() { return !this.isEditable; }
    get cardTitle() {
        return this.recordId ? 'Purchase Requisition — ' + (this.requisition.Name || '') : 'New Purchase Requisition';
    }

    validateForm() {
        if (!this.requisition.Request_Date__c) {
            this.errorMessage = 'Request Date is required.';
            return false;
        }
        const validLines = this.lines.filter(l => l.Product__c);
        if (validLines.length === 0) {
            this.errorMessage = 'At least one product line is required.';
            return false;
        }
        for (const line of validLines) {
            if (!line.Requested_Qty__c || parseFloat(line.Requested_Qty__c) <= 0) {
                this.errorMessage = 'All line quantities must be greater than zero.';
                return false;
            }
        }
        return true;
    }

    handleSave() {
        this.errorMessage = null;
        this.successMessage = null;
        if (!this.validateForm()) return;
        this.isSaving = true;
        const reqData = { ...this.requisition };
        delete reqData._key;
        const linesData = this.lines.filter(l => l.Product__c).map(l => {
            const line = { ...l };
            delete line._key;
            delete line.lineTotal;
            delete line.productName;
            return line;
        });
        saveRequisition({ requisitionJson: JSON.stringify(reqData), linesJson: JSON.stringify(linesData) })
            .then(id => {
                this.requisition = { ...this.requisition, Id: id };
                this.successMessage = 'Requisition saved successfully.';
                this.isSaving = false;
                this.dispatchEvent(new CustomEvent('saved', { detail: { id } }));
            })
            .catch(err => {
                this.errorMessage = err.body ? err.body.message : 'Error saving requisition';
                this.isSaving = false;
            });
    }

    handleSubmit() {
        this.errorMessage = null;
        this.successMessage = null;
        if (!this.validateForm()) return;
        this.isSaving = true;
        const reqId = this.requisition.Id || this.recordId;
        if (!reqId) {
            // Save first, then submit
            this.handleSaveAndSubmit();
            return;
        }
        submitRequisitionForApproval({ requisitionId: reqId })
            .then(() => {
                this.successMessage = 'Requisition submitted for approval.';
                this.isEditable = false;
                this.requisition = { ...this.requisition, Status__c: 'Submitted' };
                this.isSaving = false;
                this.dispatchEvent(new CustomEvent('submitted', { detail: { id: reqId } }));
            })
            .catch(err => {
                this.errorMessage = err.body ? err.body.message : 'Error submitting requisition';
                this.isSaving = false;
            });
    }

    handleSaveAndSubmit() {
        const reqData = { ...this.requisition };
        delete reqData._key;
        const linesData = this.lines.filter(l => l.Product__c).map(l => {
            const line = { ...l };
            delete line._key;
            delete line.lineTotal;
            delete line.productName;
            return line;
        });
        saveRequisition({ requisitionJson: JSON.stringify(reqData), linesJson: JSON.stringify(linesData) })
            .then(id => {
                this.requisition = { ...this.requisition, Id: id };
                return submitRequisitionForApproval({ requisitionId: id });
            })
            .then(() => {
                this.successMessage = 'Requisition saved and submitted for approval.';
                this.isEditable = false;
                this.requisition = { ...this.requisition, Status__c: 'Submitted' };
                this.isSaving = false;
            })
            .catch(err => {
                this.errorMessage = err.body ? err.body.message : 'Error saving/submitting';
                this.isSaving = false;
            });
    }
}
