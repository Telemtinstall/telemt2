"""Keep existing domain/IP UI, execute its mutations in the shared v3 FIFO."""
class EndpointJobs:
    def __init__(self,queue):self.queue=queue
    def enqueue(self,token,chat,domain,ip,kind='domain'):
        if kind not in {'domain','ip'}:raise ValueError('Unknown endpoint action')
        return self.queue.enqueue('endpoint:'+token,str(chat),chat,'endpoint_apply',[chat,kind,domain,ip],{})
    def recent(self):return [] # The shared jobs view already lists these tasks.
    def start(self):pass
    def close(self):pass
