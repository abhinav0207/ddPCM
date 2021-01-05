!> @copyright (c) 2020-2020 RWTH Aachen. All rights reserved.
!!
!! ddX software
!!
!! @file src/dd_operators.f90
!! Operators of ddX software
!!
!! @version 1.0.0
!! @author Aleksandr Mikhalev
!! @date 2020-12-17

!> Operators shared among ddX methods
module dd_operators
! Use underlying core routines
use dd_core

contains

!> Compute potential in cavity points
!!
!! TODO: make use of FMM here
subroutine mkrhs(n, charge, x, y, z, ncav, ccav, phi, nbasis, psi)
    ! Inputs
    integer, intent(in) :: n, ncav, nbasis
    real(kind=rp), intent(in) :: x(n), y(n), z(n), charge(n)
    real(kind=rp), intent(in) :: ccav(3, ncav)
    ! Outputs
    real(kind=rp), intent(out) :: phi(ncav)
    real(kind=rp), intent(out) :: psi(nbasis, n)
    ! Local variables
    integer :: isph, icav
    real(kind=rp) :: d(3), v
    real(kind=rp), external :: dnrm2
    ! Vector phi
    do icav = 1, ncav
        v = zero
        do isph = 1, n
            d(1) = ccav(1, icav) - x(isph)
            d(2) = ccav(2, icav) - y(isph)
            d(3) = ccav(3, icav) - z(isph)
            v = v + charge(isph)/dnrm2(3, d, 1)
        end do
        phi(icav) = v
    end do
    ! Vector psi
    psi(2:, :) = zero
    do isph = 1, n
        psi(1, isph) = sqrt4pi * charge(isph)
    end do
end subroutine mkrhs

!> Apply single layer operator to spherical harmonics
!!
!! Diagonal blocks are not counted here.
subroutine lx(dd_data, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Local variables
    integer :: isph, istatus
    real(kind=rp), allocatable :: pot(:), vplm(:), basloc(:), vcos(:), vsin(:)
    ! Allocate workspaces
    allocate(pot(dd_data % ngrid), vplm(dd_data % nbasis), &
        & basloc(dd_data % nbasis), vcos(dd_data % lmax+1), &
        & vsin(dd_data % lmax+1) , stat=istatus )
    if ( istatus.ne.0 ) then
        write(*,*) 'lx: allocation failed !'
        stop
    end if
    ! Debug printing
    if (dd_data % iprint .ge. 5) then
        call prtsph('X', dd_data % nbasis, dd_data % lmax, dd_data % nsph, 0, &
            & x)
    end if
    ! Initialize
    y = zero
    ! !!$omp parallel do default(shared) private(isph,pot,basloc,vplm,vcos,vsin) &
    ! !!$omp schedule(dynamic)
    do isph = 1, dd_data % nsph
        ! Compute NEGATIVE action of off-digonal blocks
        call calcv(dd_data, .false., isph, pot, x, basloc, vplm, vcos, vsin)
        call intrhs(dd_data % iprint, dd_data % ngrid, dd_data % lmax, &
            & dd_data % vwgrid, isph, pot, y(:,isph))
        ! Action of off-diagonal blocks
        y(:,isph) = - y(:,isph)
    end do
    ! Debug printing
    if (dd_data % iprint .ge. 5) then
        call prtsph('LX (off diagonal)', dd_data % nbasis, dd_data % lmax, &
            & dd_data % nsph, 0, y)
    end if
    ! Deallocate workspaces
    deallocate(pot, basloc, vplm, vcos, vsin , stat=istatus)
    if (istatus .ne. 0) then
        write(*,*) 'lx: allocation failed !'
        stop
    endif
end subroutine lx

!> Diagonal preconditioning for Lx operator
!!
!! Applies inverse diagonal (block) of the L matrix
subroutine ldm1x(dd_data, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Local variables
    integer :: l, ind
    ! Loop over harmonics
    do l = 0, dd_data % lmax
        ind = l*l + l + 1
        y(ind-l:ind+l, :) = x(ind-l:ind+l, :) * (dd_data % vscales(ind)**2)
    end do
end subroutine ldm1x

!> Apply double layer operator to spherical harmonics
!!
!! @param[in] dd_data
subroutine dx(dd_data, do_diag, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    integer, intent(in) :: do_diag
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Select implementation
    if (dd_data % fmm .eq. 0) then
        call dx_dense(dd_data, do_diag, x, y)
    else
        call dx_fmm(dd_data, do_diag, x, y)
    end if
end subroutine dx

!> Baseline implementation of double layer operator
!!
!! @param[in] dd_data
subroutine dx_dense(dd_data, do_diag, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    integer, intent(in) :: do_diag
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Local variables
    real(kind=rp), allocatable :: vts(:), vplm(:), basloc(:), vcos(:), vsin(:)
    real(kind=rp) :: c(3), vij(3), sij(3)
    real(kind=rp) :: vvij, tij, tt, f, f1, rho, ctheta, stheta, cphi, sphi
    integer :: its, isph, jsph, l, m, ind, lm, istatus
    ! Allocate temporaries
    allocate(vts(dd_data % ngrid), vplm(dd_data % nbasis), &
        & basloc(dd_data % nbasis),vcos(dd_data % lmax+1), &
        & vsin(dd_data % lmax+1), stat=istatus)
    if (istatus.ne.0) then
        write(6,*) 'dx: allocation failed !'
        stop
    end if
    y = zero
    ! this loop is easily parallelizable
    ! !!$omp parallel do default(none) schedule(dynamic) &
    ! !!$omp private(isph,its,jsph,basloc,vplm,vcos,vsin,vij, &
    ! !!$omp vvij,tij,sij,tt,l,ind,f,m,vts,c) &
    ! !!$omp shared(nsph,ngrid,ui,csph,rsph,grid, &
    ! !!$omp lmax,fourpi,dodiag,x,y,basis)
    do isph = 1, dd_data % nsph
        ! compute the "potential" from the other spheres
        ! at the exposed lebedv points of the i-th sphere 
        vts = zero
        do its = 1, dd_data % ngrid
            if (dd_data % ui(its,isph).gt.zero) then
                c = dd_data % csph(:,isph) + dd_data % rsph(isph)* &
                    & dd_data % cgrid(:,its)
                do jsph = 1, dd_data % nsph
                    if (jsph.ne.isph) then
                        ! build the geometrical variables
                        vij = c - dd_data % csph(:,jsph)
                        vvij = sqrt(dot_product(vij,vij))
                        tij = vvij / dd_data % rsph(jsph)
                        sij = vij/vvij 
                        ! build the local basis
                        call ylmbas(sij, rho, ctheta, stheta, cphi, sphi, &
                            & dd_data % lmax, dd_data % vscales, basloc, &
                            & vplm, vcos, vsin)
                        ! with all the required stuff, finally compute
                        ! the "potential" at the point 
                        tt = one/tij 
                        do l = 0, dd_data % lmax
                            ind = l*l + l + 1
                            f = fourpi*dble(l)/(two*dble(l) + one)*tt
                            do m = -l, l
                                vts(its) = vts(its) + f*x(ind + m,jsph) * &
                                    & basloc(ind + m)
                            end do
                            tt = tt/tij
                        end do
                    else if (do_diag .eq. 1) then
                        ! add the diagonal contribution
                        do l = 0, dd_data % lmax
                            ind = l*l + l + 1
                            f = (two*dble(l) + one)/fourpi
                            do m = -l, l
                                vts(its) = vts(its) - pt5*x(ind + m,isph) * &
                                    & dd_data % vgrid(ind + m,its)/f
                            end do
                        end do
                    end if 
                end do
                vts(its) = dd_data % ui(its,isph)*vts(its) 
            end if
        end do
        ! now integrate the potential to get its modal representation
        call intrhs(dd_data % iprint, dd_data % ngrid, dd_data % lmax, &
            & dd_data % vwgrid, isph, vts, y(:,isph))
    end do
    ! Clean up temporary data
    deallocate(vts,vplm,basloc,vcos,vsin,stat=istatus)
    if (istatus.ne.0) then
        write(6,*) 'dx: deallocation failed !'
        stop
    end if
end subroutine dx_dense

!> FMM-accelerated implementation of double layer operator
!!
!! @param[in] dd_data
subroutine dx_fmm(dd_data, do_diag, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    integer, intent(in) :: do_diag
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Local variables
end subroutine dx_fmm

!> Apply adjoint double layer operator to spherical harmonics
!!
!! @param[in] dd_data
subroutine dstarx(dd_data, do_diag, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    integer, intent(in) :: do_diag
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Select implementation
    if (dd_data % fmm .eq. 0) then
        call dstarx_dense(dd_data, do_diag, x, y)
    else
        call dstarx_fmm(dd_data, do_diag, x, y)
    end if
end subroutine dstarx

!> Baseline implementation of adjoint double layer operator
!!
!!
subroutine dstarx_dense(dd_data, do_diag, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    integer, intent(in) :: do_diag
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Local variables
    real(kind=rp), allocatable :: vts(:), vplm(:), basloc(:), vcos(:), vsin(:)
    real(kind=rp) :: c(3), vji(3), sji(3)
    real(kind=rp) :: vvji, tji, fourpi, tt, f, f1, rho, ctheta, stheta, cphi, sphi
    integer :: its, isph, jsph, l, m, ind, lm, istatus
    ! Allocate temporaries
    allocate(vts(dd_data % ngrid), vplm(dd_data % nbasis), &
        & basloc(dd_data % nbasis),vcos(dd_data % lmax+1), &
        & vsin(dd_data % lmax+1), stat=istatus)
    if (istatus.ne.0) then
        write(6,*) 'dx: allocation failed !'
        stop
    end if
    y = zero
    ! this loop is easily parallelizable
    ! !!$omp parallel do default(none) schedule(dynamic) &
    ! !!$omp private(isph,its,jsph,basloc,vplm,vcos,vsin,vji, &
    ! !!$omp vvji,tji,sji,tt,l,ind,f,m,vts,c) &
    ! !!$omp shared(nsph,ngrid,ui,csph,rsph,grid,facl, &
    ! !!$omp lmax,fourpi,dodiag,x,y,basis,w,nbasis)
    do isph = 1, dd_data % nsph
        do jsph = 1, dd_data % nsph
            if (jsph.ne.isph) then
                do its = 1, dd_data % ngrid
                    if (dd_data % ui(its,jsph).gt.zero) then
                        ! build the geometrical variables
                        vji = dd_data % csph(:,jsph) + dd_data % rsph(jsph) * &
                            & dd_data % cgrid(:,its) - dd_data % csph(:,isph)
                        vvji = sqrt(dot_product(vji,vji))
                        tji = vvji/dd_data % rsph(isph)
                        sji = vji/vvji
                        ! build the local basis
                        call ylmbas(sji, rho, ctheta, stheta, cphi, sphi, &
                            & dd_data % lmax, dd_data % vscales, basloc, &
                            & vplm, vcos, vsin)
                        tt = dd_data % ui(its,jsph)*dot_product(dd_data % vwgrid(:,its),x(:,jsph))/tji
                        do l = 0, dd_data % lmax
                            ind = l*l + l + 1
                            f = dble(l)*tt/ dd_data % vscales(ind)**2
                            do m = -l, l
                                y(ind+m,isph) = y(ind+m,isph) + f*basloc(ind+m)
                            end do
                            tt = tt/tji
                        end do
                    end if
                end do
            else if (do_diag .eq. 1) then
                do its = 1, dd_data % ngrid
                    f = pt5*dd_data % ui(its,jsph)*dot_product(dd_data % vwgrid(:,its),x(:,jsph))
                    do ind = 1, (dd_data % lmax+1)**2
                        y(ind,isph) = y(ind,isph) - f*dd_data % vgrid(ind,its)/dd_data % vscales(ind)**2
                    end do
                end do
            end if
        end do
    end do
    deallocate(vts,vplm,basloc,vcos,vsin,stat=istatus)
    if (istatus.ne.0) then
        write(6,*) 'dx: deallocation failed !'
        stop
    end if
end subroutine dstarx_dense

!> FMM-accelerated implementation of adjoint double layer operator
!!
!!
subroutine dstarx_fmm(dd_data, do_diag, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    integer, intent(in) :: do_diag
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Local variables
end subroutine dstarx_fmm

!> Apply \f$ R \f$ operator to spherical harmonics
!!
!! Compute \f$ y = R x = - D x \f$ with excluded diagonal influence (blocks
!! D_ii are assumed to be zero).
!!
!! @param[in] dd_data:
!! @param[in] x:
!! @param[out] y:
subroutine rx(dd_data, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Local variables
    real(kind=rp) :: fac
    ! Output `y` is cleaned here
    call dx(dd_data, 0, x, y)
    y = -y
end subroutine rx

!> Apply \f$ R_\varepsilon \f$ operator to spherical harmonics
!!
!! Compute \f$ y = R_\varepsilon x = (2\pi(\varepsilon + 1) / (\varepsilon
!! - 1) - D) x \f$.
!!
!! @param[in] dd_data:
!! @param[in] x:
!! @param[out] y:
subroutine repsx(dd_data, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Local variables
    real(kind=rp) :: fac
    ! Output `y` is cleaned here
    call dx(dd_data, 1, x, y)
    ! Apply diagonal
    fac = twopi * (dd_data % eps + one) / (dd_data % eps - one)
    y = fac*x - y
    call prtsph("matvec x", dd_data % nbasis, dd_data % lmax, dd_data % nsph, 0, y)
end subroutine repsx

!> Apply \f$ R_\infty \f$ operator to spherical harmonics
!!
!! Compute \f$ y = R_\infty x = (2\pi - D) x \f$.
!!
!! @param[in] dd_data:
!! @param[in] x:
!! @param[out] y:
subroutine rinfx(dd_data, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Local variables
    real(kind=rp) :: fac
    ! Output `y` is cleaned here
    call dx(dd_data, 1, x, y)
    ! Apply diagonal
    y = twopi*x - y
end subroutine rinfx

!> Apply adjoint f$ R_\varepsilon \f$ operator to spherical harmonics
!!
!! Compute \f$ y = R_\varepsilon^* x = (2\pi(\varepsilon + 1) / (\varepsilon
!! - 1) - D^*) x \f$.
!!
!! @param[in] dd_data:
!! @param[in] x:
!! @param[out] y:
subroutine rstarepsx(dd_data, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    ! Output
    real(kind=rp), intent(out) :: y(dd_data % nbasis, dd_data % nsph)
    ! Local variables
    real(kind=rp) :: fac
    ! Output `y` is cleaned here
    call dstarx(dd_data, 1, x, y)
    ! Apply diagonal
    fac = twopi * (dd_data % eps + one) / (dd_data % eps - one)
    y = fac*x - y
end subroutine rstarepsx

!> Apply preconditioner for 
subroutine apply_repsx_prec(dd_data, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    real(kind=rp), intent(in) :: x(dd_data % nbasis, dd_data % nsph)
    real(kind=rp), intent(inout) :: y(dd_data % nbasis, dd_data % nsph)
    integer :: isph
    ! simply do a matrix-vector product with the transposed preconditioner 
    ! !!$omp parallel do default(shared) schedule(dynamic) &
    ! !!$omp private(isph)
    do isph = 1, dd_data % nsph
        call dgemm('N', 'N', dd_data % nbasis, 1, dd_data % nbasis, one, &
            & dd_data % rx_prc(:, :, isph), dd_data % nbasis, x(:, isph), &
            dd_data % nbasis, zero, y(:, isph), dd_data % nbasis)
    end do
  call prtsph("rx_prec x", dd_data % nbasis, dd_data % lmax, dd_data % nsph, 0, x)
  call prtsph("rx_prec y", dd_data % nbasis, dd_data % lmax, dd_data % nsph, 0, y)
end subroutine apply_repsx_prec

!> Apply preconditioner for 
subroutine apply_rstarepsx_prec(dd_data, x, y)
    ! Inputs
    type(dd_data_type), intent(in) :: dd_data
    real(kind=rp), intent(in) :: x((dd_data % lmax+1)**2, dd_data % nsph)
    real(kind=rp), intent(inout) :: y((dd_data % lmax+1)**2, dd_data % nsph)
    integer :: isph
    ! simply do a matrix-vector product with the transposed preconditioner 
    ! !!$omp parallel do default(shared) schedule(dynamic) &
    ! !!$omp private(isph)
    do isph = 1, dd_data % nsph
        call dgemm('T', 'N', dd_data % nbasis, 1, dd_data % nbasis, one, &
            & dd_data % rx_prc(:, :, isph), dd_data % nbasis, x(:, isph), &
            dd_data % nbasis, zero, y(:, isph), dd_data % nbasis)
    end do
end subroutine apply_rstarepsx_prec

end module dd_operators