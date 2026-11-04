import { LightningElement, track } from 'lwc';
import getAllSupplierRankings from '@salesforce/apex/SupplierPerformanceService.getAllSupplierRankings';
import getSupplierScorecards from '@salesforce/apex/SupplierPerformanceService.getSupplierScorecards';

const RANKING_COLUMNS = [
    { label: 'Supplier', fieldName: 'supplierName', sortable: true },
    { label: 'Overall Score', fieldName: 'overallScore', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: 'On-Time Rate', fieldName: 'onTimeRate', type: 'percent', typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Defect Rate', fieldName: 'defectRate', type: 'percent', typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Avg Lead Time', fieldName: 'avgLeadTime', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Risk Level', fieldName: 'riskLevel' },
    { label: 'Orders', fieldName: 'ordersEvaluated', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Last Period', fieldName: 'latestPeriodEnd', type: 'date' },
    { type: 'action', typeAttributes: { rowActions: [{ label: 'View Scorecard History', name: 'view' }] } }
];

const SCORECARD_COLUMNS = [
    { label: 'Period Start', fieldName: 'Period_Start__c', type: 'date' },
    { label: 'Period End', fieldName: 'Period_End__c', type: 'date' },
    { label: 'Overall Score', fieldName: 'Overall_Score__c', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'On-Time Rate', fieldName: 'On_Time_Rate__c', type: 'percent', typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Defect Rate', fieldName: 'Defect_Rate__c', type: 'percent', typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Avg Lead Time', fieldName: 'Average_Lead_Time__c', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Risk Level', fieldName: 'Risk_Level__c' },
    { label: 'Orders', fieldName: 'Orders_Evaluated__c', type: 'number', cellAttributes: { alignment: 'right' } }
];

export default class SupplierPerformanceDashboard extends LightningElement {
    @track rankings = [];
    @track filteredRankings = [];
    @track selectedScorecards = [];
    @track selectedSupplierName = '';
    @track isLoading = false;
    @track error = null;
    @track riskFilter = 'All';
    @track supplierFilter = null;

    rankingColumns = RANKING_COLUMNS;
    scorecardColumns = SCORECARD_COLUMNS;

    riskOptions = [
        { label: 'All Risk Levels', value: 'All' },
        { label: 'Low', value: 'Low' },
        { label: 'Medium', value: 'Medium' },
        { label: 'High', value: 'High' }
    ];

    connectedCallback() { this.loadRankings(); }

    loadRankings() {
        this.isLoading = true;
        this.error = null;
        getAllSupplierRankings({ limitCount: 50 })
            .then(data => {
                this.rankings = data;
                this.applyFilters();
                this.isLoading = false;
            })
            .catch(err => {
                this.error = err.body ? err.body.message : 'Error loading rankings';
                this.isLoading = false;
            });
    }

    applyFilters() {
        let filtered = [...this.rankings];
        if (this.riskFilter !== 'All') filtered = filtered.filter(r => r.riskLevel === this.riskFilter);
        if (this.supplierFilter) filtered = filtered.filter(r => r.supplierId === this.supplierFilter);
        this.filteredRankings = filtered;
    }

    handleRiskFilterChange(event) {
        this.riskFilter = event.detail.value;
        this.applyFilters();
    }

    handleSupplierFilterChange(event) {
        this.supplierFilter = event.detail.recordId;
        this.applyFilters();
    }

    handleViewScorecard(event) {
        const action = event.detail.action;
        if (action.name === 'view') {
            const row = event.detail.row;
            this.selectedSupplierName = row.supplierName;
            getSupplierScorecards({ supplierId: row.supplierId })
                .then(data => { this.selectedScorecards = data; })
                .catch(err => { this.error = err.body ? err.body.message : 'Error loading scorecards'; });
        }
    }

    handleRefresh() {
        this.selectedScorecards = [];
        this.loadRankings();
    }

    get hasRankings() { return !this.isLoading && !this.error && this.filteredRankings.length > 0; }
    get hasScorecard() { return this.selectedScorecards.length > 0; }
    get isEmpty() { return !this.isLoading && !this.error && this.rankings.length === 0; }
}
