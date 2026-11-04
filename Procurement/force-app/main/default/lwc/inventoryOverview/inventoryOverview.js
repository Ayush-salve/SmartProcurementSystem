import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getInventoryRecords from '@salesforce/apex/InventoryService.getInventoryRecords';
import getActiveWarehouses from '@salesforce/apex/InventoryService.getActiveWarehouses';

const PAGE_SIZE = 10;

const COLUMNS = [
    { label: 'Product', fieldName: 'productLink', type: 'url',
      typeAttributes: { label: { fieldName: 'productName' }, target: '_self' } },
    { label: 'Warehouse', fieldName: 'warehouseName', sortable: true },
    { label: 'On Hand', fieldName: 'onHand', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: 'Reserved', fieldName: 'reserved', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Available', fieldName: 'available', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: 'Reorder Pt.', fieldName: 'reorderPoint', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Status', fieldName: 'reorderStatus', type: 'text',
      cellAttributes: { class: { fieldName: 'statusClass' } } },
    { label: 'Last Check', fieldName: 'lastStockCheck', type: 'date', sortable: true },
    { type: 'action', typeAttributes: { rowActions: [{ label: 'View Record', name: 'view' }] } }
];

export default class InventoryOverview extends NavigationMixin(LightningElement) {
    @track inventoryData = [];
    @track filteredData = [];
    @track isLoading = false;
    @track error = null;
    @track searchTerm = '';
    @track reorderStatusFilter = 'All';
    @track warehouseFilter = 'All';
    @track warehouseOptions = [{ label: 'All Warehouses', value: 'All' }];
    @track sortedBy = 'reorderStatus';
    @track sortedDirection = 'asc';
    @track currentPage = 1;

    columns = COLUMNS;

    statusOptions = [
        { label: 'All Statuses', value: 'All' },
        { label: 'Reorder Needed', value: 'Reorder Needed' },
        { label: 'At Risk', value: 'At Risk' },
        { label: 'Healthy', value: 'Healthy' }
    ];

    connectedCallback() {
        this.loadWarehouses();
        this.loadInventory();
    }

    loadWarehouses() {
        getActiveWarehouses()
            .then(data => {
                const opts = [{ label: 'All Warehouses', value: 'All' }];
                data.forEach(wh => opts.push({ label: wh.Name, value: wh.Id }));
                this.warehouseOptions = opts;
            })
            .catch(() => {});
    }

    loadInventory() {
        this.isLoading = true;
        this.error = null;
        getInventoryRecords({ searchTerm: this.searchTerm, reorderStatusFilter: this.reorderStatusFilter })
            .then(data => {
                this.inventoryData = data.map(item => ({
                    ...item,
                    productLink: '/lightning/r/Product2/' + item.productId + '/view',
                    statusClass: item.reorderStatus === 'Reorder Needed' ? 'slds-text-color_error'
                                : item.reorderStatus === 'At Risk' ? 'slds-text-color_warning' : 'slds-text-color_success'
                }));
                this.applyWarehouseFilter();
                this.currentPage = 1;
                this.isLoading = false;
            })
            .catch(err => {
                this.error = err.body ? err.body.message : 'Error loading inventory';
                this.isLoading = false;
            });
    }

    applyWarehouseFilter() {
        if (this.warehouseFilter === 'All') {
            this.filteredData = [...this.inventoryData];
        } else {
            this.filteredData = this.inventoryData.filter(i => i.warehouseId === this.warehouseFilter);
        }
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        clearTimeout(this._searchTimeout);
        this._searchTimeout = setTimeout(() => this.loadInventory(), 400);
    }

    handleStatusFilterChange(event) {
        this.reorderStatusFilter = event.detail.value;
        this.loadInventory();
    }

    handleWarehouseFilterChange(event) {
        this.warehouseFilter = event.detail.value;
        this.applyWarehouseFilter();
        this.currentPage = 1;
    }

    handleRefresh() { this.loadInventory(); }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortedDirection = event.detail.sortDirection;
        const sorted = [...this.filteredData].sort((a, b) => {
            const valA = a[this.sortedBy] != null ? a[this.sortedBy] : '';
            const valB = b[this.sortedBy] != null ? b[this.sortedBy] : '';
            const mult = this.sortedDirection === 'asc' ? 1 : -1;
            return valA > valB ? mult : valA < valB ? -mult : 0;
        });
        this.filteredData = sorted;
    }

    handleRowAction(event) {
        const action = event.detail.action;
        const row = event.detail.row;
        if (action.name === 'view') {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: row.inventoryId, actionName: 'view' }
            });
        }
    }

    handlePreviousPage() { if (this.currentPage > 1) this.currentPage--; }
    handleNextPage() { if (this.currentPage < this.totalPages) this.currentPage++; }

    get paginatedData() {
        const start = (this.currentPage - 1) * PAGE_SIZE;
        return this.filteredData.slice(start, start + PAGE_SIZE);
    }

    get totalPages() { return Math.max(1, Math.ceil(this.filteredData.length / PAGE_SIZE)); }
    get totalItems() { return this.filteredData.length; }
    get isFirstPage() { return this.currentPage === 1; }
    get isLastPage() { return this.currentPage >= this.totalPages; }
    get hasData() { return !this.isLoading && !this.error && this.filteredData.length > 0; }
    get isEmpty() { return !this.isLoading && !this.error && this.filteredData.length === 0; }
    get rowNumberOffset() { return (this.currentPage - 1) * PAGE_SIZE; }

    get reorderNeededCount() { return this.filteredData.filter(i => i.reorderStatus === 'Reorder Needed').length; }
    get atRiskCount() { return this.filteredData.filter(i => i.reorderStatus === 'At Risk').length; }
    get healthyCount() { return this.filteredData.filter(i => i.reorderStatus === 'Healthy').length; }
}
