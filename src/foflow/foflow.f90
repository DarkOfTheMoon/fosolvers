!----------------------------------------------------------------------------- best with 100 columns

!> foflow main program
program foflow
  use moduleBasicDataStruct
  use moduleFileIO
  use moduleGrid
  use moduleGridOperation
  use moduleInterpolation
  use moduleFVMGrad
  use moduleFVMConvect
  use moduleNonlinearSolve
  use moduleCLIO
  use miscNS
  double precision pWork !< pressure work done on block surface
  external::resMom
  external::resEnergy
  external::resPressure
  double precision,allocatable::u1d(:) !< unwrapped velocity
  
  ! read simulation control file
  open(11,file='bin/sim',status='old')
  call readSim(11)
  close(11)
  ! read grid
  open(11,file='bin/gridGMSH5.msh',status='old')
  call readGMSH(11,grid)
  call grid%updateIntf()
  close(11)
  ! read conditions
  open(11,file='bin/cond',status='old')
  call readCondition(11,condition)
  close(11)
  ! allocate storage
  call setEnv()
  allocate(u1d(DIMS*grid%nNode))
  ! simulation control
  dt=1d-5
  ! initial value of variables
  call grid%updateBlockPos()
  call grid%updateDualBlock()
  call grid%updateBlockVol()
  l=findCondition(condition,0,'Initial_States')
  forall(i=1:grid%nNode)
    u(1,i)=condition(l)%dat%get('Initial_U',grid%NodePos(:,i))
    u(2,i)=condition(l)%dat%get('Initial_V',grid%NodePos(:,i))
    u(3,i)=condition(l)%dat%get('Initial_W',grid%NodePos(:,i))
  end forall
  forall(i=1:grid%nBlock)
    Temp(i)=condition(l)%dat%get('Initial_Temperature',grid%BlockPos(:,i))
    p(i)=condition(l)%dat%get('Initial_Pressure',grid%BlockPos(:,i))
  end forall
  gamm(:)=1.4d0
  forall(i=1:grid%nBlock)
    rho(i)=p(i)/200d0/Temp(i) !TODO:rho=rho(p,T), Ru=200
    IE(i)=200d0*Temp(i)/(gamm(i)-1d0) !TODO:IE=IE(p,T), Ru=200
    E(i)=IE(i) !zero velocity
    rhoE(i)=rho(i)*E(i)
  end forall
  rhoNode=itplBlock2Node(rho,grid)
  forall(i=1:grid%nNode)
    rhou(:,i)=u(:,i)*rhoNode(i)
    Mom(:,i)=rhou(:,i)*grid%NodeVol(i)
  end forall
  Mass(:)=rho(:)*grid%BlockVol(:)
  IEnergy(:)=IE(:)*Mass(:)
  Energy(:)=E(:)*Mass(:)
  visc(:)=1d-3 !TODO: mu, k are functions of T,p
  viscRate(:)=-2d0/3d0
  thermK(:)=1d-4
  t=0d0
  iWrite=0
  ! write initial states
  open(13,file='rstNS.msh',status='replace')
  call writeGMSH(13,grid)
  call writeGMSH(13,rho,grid,BIND_BLOCK,'rho',iWrite,t)
  call writeGMSH(13,u,grid,BIND_NODE,'u',iWrite,t)
  call writeGMSH(13,p,grid,BIND_BLOCK,'p',iWrite,t)
  call writeGMSH(13,Temp,grid,BIND_BLOCK,'T',iWrite,t)
  ! advance in time
  do while(t<tFinal)
    call grid%updateDualBlock()
    call grid%updateBlockVol()
    call grid%updateFacetNorm()
    call grid%updateIntfArea()
    call grid%updateIntfNorm()
    ! Lagrangian step
    preU(:,:)=u(:,:)
    oldU(:,:)=u(:,:)
    oldP(:)=p(:)
    oldMom(:,:)=Mom(:,:)
    oldEnergy(:)=Energy(:)
    preP(:)=p(:)
    do iCoup=1,10
      ! solve momentum equation for velocity using assumed pressure
      rhoNode=itplBlock2Node(rho,grid)
      u1d(:)=reshape(u,[DIMS*grid%nNode])
      if(maxval(abs(u1d))<=tiny(1d0))then
        u1d(:)=1d0
      end if
      ProblemFunc=>resMom
      call solveNonlinear(u1d)
      u=reshape(u1d,[DIMS,grid%nNode])
      forall(i=1:grid%nNode)
        rhou(:,i)=u(:,i)*rhoNode(i)
        Mom(:,i)=rhou(:,i)*grid%NodeVol(i)
      end forall
      ! solve energy equation for temperature, exclude pressure work
      tao=findTao(u)
      uBlock=itplNode2Block(u,grid)
      uIntf=itplNode2Intf(u,grid)
      taoIntf=itplBlock2Intf(tao,grid)
      ProblemFunc=>resEnergy
      call solveNonlinear(Temp)
      forall(i=1:grid%nBlock)
        IE(i)=Temp(i)*200d0/(gamm(i)-1d0) !TODO:IE=IE(p,T)
        E(i)=IE(i)+dot_product(uBlock(:,i),uBlock(:,i))/2d0
        rhoE(i)=rho(i)*E(i)
        IEnergy(i)=IE(i)*Mass(i)
        Energy(i)=E(i)*Mass(i)
      end forall
      ! remove from the momentum equation the effect of assumed pressure
      do i=1,grid%nNode
        do j=1,size(grid%NodeNeibBlock(i)%dat)
          Mom(:,i)=Mom(:,i)+dt*grid%NBAreaVect(i)%dat(:,j)*p(grid%NodeNeibBlock(i)%dat(j))
        end do
        if(allocated(grid%NodeNeibFacet(i)%dat))then
          do j=1,size(grid%NodeNeibFacet(i)%dat)
            k=grid%NodeNeibFacet(i)%dat(j)
            l=findCondition(condition,grid%Facet(k)%Ent,'Inlet')
            if(l>0)then
              if(condition(l)%dat%test('Inlet_Pressure'))then
                Mom(:,i)=Mom(:,i)!TODO:remove the boundary pressure
              end if
            end if
          end do
        end if
      end do
      ! couple pressure with fluid displacement, add pressure effects on momentum and energy
      ProblemFunc=>resPressure
      call solveNonlinear(p)
      do i=1,grid%nNode
        do j=1,size(grid%NodeNeibBlock(i)%dat)
          Mom(:,i)=Mom(:,i)-dt*grid%NBAreaVect(i)%dat(:,j)*p(grid%NodeNeibBlock(i)%dat(j))
        end do
        if(allocated(grid%NodeNeibFacet(i)%dat))then
          do j=1,size(grid%NodeNeibFacet(i)%dat)
            k=grid%NodeNeibFacet(i)%dat(j)
            l=findCondition(condition,grid%Facet(k)%Ent,'Inlet')
            if(l>0)then
              if(condition(l)%dat%test('Inlet_Pressure'))then
                Mom(:,i)=Mom(:,i)!TODO:add the boundary pressure
              end if
            end if
          end do
        end if
        do j=1,size(grid%NodeNeibBlock(i)%dat)
          rhou(:,i)=Mom(:,i)/grid%NodeVol(i)
          u(:,i)=rhou(:,i)/rhoNode(i)
        end do
      end do
      pIntf=itplBlock2Intf(p,grid)
      do i=1,grid%nIntf
        m=grid%IntfNeibBlock(1,i)
        n=grid%IntfNeibBlock(2,i)
        pWork=dt*pIntf(i)*grid%IntfArea(i)*dot_product(grid%IntfNorm(:,i),uIntf(:,i))
        Energy(m)=Energy(m)-pWork
        Energy(n)=Energy(n)+pWork
      end do
      do i=1,grid%nFacet
        l=findCondition(condition,grid%Facet(i)%Ent,'Inlet')
        if(l>0)then
          if(condition(l)%dat%test('Inlet_Pressure'))then
            m=maxval(grid%FacetNeibBlock(:,i))
            !TODO:add the boundary pressure work
          end if
        end if
      end do
      rhoE(:)=Energy(:)/grid%BlockVol(:)
      E(:)=rhoE(:)/rho(:)
      uBlock=itplNode2Block(u,grid)
      forall(i=1:grid%nBlock)
        IE(i)=E(i)-dot_product(uBlock(:,i),uBlock(:,i))/2d0
        IEnergy(i)=IE(i)*Mass(i)
      end forall
      ! Evaluate error and further coupling if necessary
      if(norm2(u(:,:))>tiny(1d0))then
        errCoup=norm2(u(:,:)-preU(:,:))/norm2(u(:,:))
      else
        errCoup=norm2(u(:,:)-preU(:,:))
      end if
      write(*,*),iCoup,errCoup
      if(errCoup<TOLERANCE_COUP)then
        exit
      else
        preU(:,:)=u(:,:)
        u(:,:)=oldU(:,:)
        p(:)=P_RELAX_FACT*p(:)+(1d0-P_RELAX_FACT)*preP(:)
        preP(:)=p(:)
        Mom(:,:)=oldMom(:,:)
        Energy(:)=oldEnergy(:)
      end if
    end do
    call mvGrid(grid,dt*u)
    ! Euler rezoning
    ! Boundary convection
    disp(:,:)=0d0
    do i=1,grid%nFacet
      l=findCondition(condition,grid%Facet(i)%Ent,'Inlet')
      if(l>0)then
        disp(:,grid%Facet(i)%iNode(:))=-dt*u(:,grid%Facet(i)%iNode(:))
      end if
    end do
    !TODO:boundary convection
    call mvGrid(grid,disp)
    ! rezoning of inner nodes
    disp(:,:)=-dt*u(:,:)
    do i=1,grid%nFacet
      l=findCondition(condition,grid%Facet(i)%Ent,'Inlet')
      if(l>0)then
        disp(:,grid%Facet(i)%iNode(:))=0d0
      end if
    end do
    gradRho=findGrad(rho,grid,BIND_BLOCK)
    gradRhou=findGrad(rhou,grid,BIND_NODE)
    gradRhoE=findGrad(rhoE,grid,BIND_BLOCK)
    Mass=Mass+findDispConvect(rho,BIND_BLOCK,disp,grid,gradRho,limiter=vanLeer)
    Mom=Mom+findDispConvect(rhou,BIND_NODE,disp,grid,gradRhou,limiter=vanLeer)
    Energy=Energy+findDispConvect(rhoE,BIND_BLOCK,disp,grid,gradRhoE,limiter=vanLeer)
    call mvGrid(grid,disp)
    ! recover state
    call grid%updateDualBlock()
    call grid%updateBlockVol()
    rhoNode=itplBlock2Node(rho,grid)
    forall(i=1:grid%nNode)
      rhou(:,i)=Mom(:,i)/grid%NodeVol(i)
      u(:,i)=rhou(:,i)/rhoNode(i)
    end forall
    uBlock=itplNode2Block(u,grid)
    forall(i=1:grid%nBlock)
      rhoE(i)=Energy(i)/grid%BlockVol(i)
      E(i)=rhoE(i)/rho(i)
      IE(i)=E(i)-dot_product(uBlock(:,i),uBlock(:,i))/2d0
      IEnergy(i)=IE(i)*Mass(i)
      p(i)=IE(i)*rho(i)*(gamm(i)-1d0) !TODO:p=p(rho,T)
      Temp(i)=IE(i)*(gamm(i)-1d0)/200d0 !TODO:T=T(IE,p)
    end forall
    rho(:)=Mass(:)/grid%BlockVol(:)
    t=t+dt
    ! write results
    if(t/tWrite>=iWrite)then
      iWrite=iWrite+1
      call writeGMSH(13,rho,grid,BIND_BLOCK,'rho',iWrite,t)
      call writeGMSH(13,u,grid,BIND_NODE,'u',iWrite,t)
      call writeGMSH(13,p,grid,BIND_BLOCK,'p',iWrite,t)
      call writeGMSH(13,Temp,grid,BIND_BLOCK,'T',iWrite,t)
    end if
    call showProg(t/tFinal)
  end do
  write(*,*),''
  call clearEnv()
  deallocate(u1d)
  close(13)
end program